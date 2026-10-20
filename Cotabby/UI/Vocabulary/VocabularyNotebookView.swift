import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A normal document-like window, not another settings pane. The environment injects the same
/// store used by cards and the existing speech controller; this view owns only browsing state.
struct VocabularyNotebookView: View {
    @ObservedObject var store: VocabularyStore
    let speech: LearningSpeechController
    @State private var selection: UUID?
    @State private var query = ""
    @State private var language: LearningLanguage?
    @State private var newestFirst = true
    @State private var editing: VocabularyEntry?
    @State private var deleting: VocabularyEntry?
    @State private var requestedID: UUID?

    init(store: VocabularyStore, speech: LearningSpeechController, selectedID: UUID? = nil) {
        self.store = store
        self.speech = speech
        _selection = State(initialValue: selectedID)
        _requestedID = State(initialValue: selectedID)
    }

    private var visibleEntries: [VocabularyEntry] {
        store.entries.filter { (language == nil || $0.language == language) && VocabularyPolicy.matches($0, query: query) }
            .sorted { newestFirst ? $0.updatedAt > $1.updatedAt : $0.updatedAt < $1.updatedAt }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(visibleEntries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.expression).font(.headline).lineLimit(2)
                        if !entry.meaning.isEmpty { Text(entry.meaning).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                        if let example = entry.examples.first, example.text != entry.expression {
                            Text(example.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, 4).tag(entry.id)
                }
            }
            .overlay {
                if visibleEntries.isEmpty {
                    ContentUnavailableView(query.isEmpty
                        ? String(localized: "No saved expressions", table: "Vocabulary")
                        : String(localized: "No matching expressions", table: "Vocabulary"), systemImage: "books.vertical")
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 420)
        } detail: {
            if let entry = store.entries.first(where: { $0.id == selection }) {
                VocabularyEntryDetail(entry: entry, speech: speech,
                    edit: { editing = entry }, delete: { deleting = entry })
                    .id(entry.id)
            } else {
                ContentUnavailableView(String(localized: "Vocabulary", table: "Vocabulary"), systemImage: "books.vertical")
            }
        }
        .searchable(text: $query, prompt: String(localized: "Search vocabulary", table: "Vocabulary"))
        .toolbar {
            ToolbarItem {
                Picker(String(localized: "Language", table: "Vocabulary"), selection: $language) {
                    Text(String(localized: "All languages", table: "Vocabulary")).tag(nil as LearningLanguage?)
                    ForEach(LearningLanguage.allCases) { Text($0.label).tag(Optional($0)) }
                }.frame(maxWidth: 150)
            }
            ToolbarItem {
                Button {
                    newestFirst.toggle()
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .help(newestFirst ? String(localized: "Newest first", table: "Vocabulary")
                    : String(localized: "Oldest first", table: "Vocabulary"))
            }
            ToolbarItem {
                Button(action: export) { Image(systemName: "square.and.arrow.up") }
                    .help(String(localized: "Export notebook…", table: "Vocabulary"))
                    .disabled(!store.isLoaded || store.entries.isEmpty)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { store.loadIfNeeded() }
        .onChange(of: store.entries) { _, entries in
            if let requestedID, entries.contains(where: { $0.id == requestedID }) {
                selection = requestedID
                self.requestedID = nil
            } else if let selection, !entries.contains(where: { $0.id == selection }) { self.selection = nil }
        }
        .sheet(item: $editing) { VocabularyEntryEditor(entry: $0, store: store) }
        .alert(String(localized: "Delete this expression?", table: "Vocabulary"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(String(localized: "Cancel"), role: .cancel) { deleting = nil }
                Button(String(localized: "Delete"), role: .destructive) {
                    if let id = deleting?.id { Task { _ = await store.remove(id: id) } }
                    deleting = nil
                }
            }
        .alert(String(localized: "Vocabulary operation failed", table: "Vocabulary"), isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Lingrove-vocabulary.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await store.export(to: url) }
        }
    }
}

/// Read-only browsing reuses the app's speech button and material cards. Edits are explicit sheets
/// so selecting another row cannot silently discard an in-progress note or sentence change.
private struct VocabularyEntryDetail: View {
    let entry: VocabularyEntry
    let speech: LearningSpeechController
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    Text(entry.expression).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Spacer()
                    speaker(text: entry.expression, item: "expression", language: entry.language)
                    VocabularyFavoriteIcon(isSaved: true).frame(width: 20, height: 20)
                }
                Text(entry.language.label + " · " + entry.kind.label).font(.caption).foregroundStyle(.secondary)
                if entry.dictionaryForm != entry.expression {
                    Text(entry.dictionaryForm).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !entry.meaning.isEmpty { Text(entry.meaning).textSelection(.enabled) }
                ForEach(entry.standaloneMeanings.filter { !$0.text.isEmpty && $0.language != entry.meaningLanguage }) { meaning in
                    VStack(alignment: .leading, spacing: 5) {
                        if let language = meaning.language { Text(language.label).font(.caption).foregroundStyle(.secondary) }
                        Text(meaning.text).textSelection(.enabled)
                    }
                }
                if !entry.tags.isEmpty { Text(entry.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                if !entry.note.isEmpty {
                    section(String(localized: "Notes", table: "Vocabulary")) { Text(entry.note).textSelection(.enabled) }
                }
                ForEach(entry.examples) { example in
                    section(example.completeness == .sentence
                        ? String(localized: "Example sentence", table: "Vocabulary")
                        : String(localized: "Context fragment", table: "Vocabulary")) {
                        HStack(alignment: .top) {
                            Text(highlighted(example)).textSelection(.enabled)
                            Spacer(minLength: 4)
                            speaker(text: example.text, item: example.id.uuidString, language: entry.language)
                        }
                        if !example.translation.isEmpty {
                            HStack(alignment: .top) {
                                Text(example.translation).foregroundStyle(.secondary).textSelection(.enabled)
                                Spacer(minLength: 4)
                                speaker(text: example.translation, item: example.id.uuidString + ".translation",
                                    language: example.translationLanguage ?? entry.language)
                            }
                        }
                        if !example.meaning.isEmpty { Text(example.meaning).font(.callout).textSelection(.enabled) }
                        if let app = example.appBundleIdentifier,
                           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                            Text(FileManager.default.displayName(atPath: url.path))
                                .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                        }
                    }
                }
                ForEach(Array(entry.definitions.enumerated()), id: \.offset) { _, definition in
                    section(String(localized: "Dictionary", table: "Vocabulary")) {
                        Text(definition.text).textSelection(.enabled)
                        if let url = URL(string: definition.sourceURL) {
                            Link(definition.source, destination: url).font(.caption)
                        }
                        if let license = URL(string: definition.licenseURL) {
                            Link("CC BY-SA 4.0", destination: license).font(.caption2)
                        }
                    }
                }
                Text(entry.createdAt, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.tertiary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(String(localized: "Edit", table: "Vocabulary"), action: edit)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.expression, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help(String(localized: "Copy expression", table: "Vocabulary"))
                Button(action: delete) { Image(systemName: "trash") }
                    .help(String(localized: "Delete", table: "Vocabulary"))
            }
        }
        .onDisappear { speech.stop(ownerID: entry.id) }
    }

    private func speaker(text: String, item: String, language: LearningLanguage) -> some View {
        LearningSpeechButton(speech: speech, request: SpeechRequest(target: SpeechTarget(ownerID: entry.id, itemID: "vocabulary." + item),
            text: text, language: language), playLabel: String(localized: "Read aloud", table: "Vocabulary"),
            stopLabel: String(localized: "Stop reading", table: "Vocabulary"))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func highlighted(_ example: VocabularyExample) -> AttributedString {
        var result = AttributedString(example.text)
        for value in example.ranges {
            guard VocabularyPolicy.valid(value.nsRange, in: example.text), let range = Range(value.nsRange, in: example.text),
                  let converted = Range(range, in: result) else { continue }
            result[converted].font = .body.bold()
            result[converted].foregroundColor = .blue
        }
        return result
    }
}

extension VocabularyEntry.Kind {
    var label: String {
        switch self {
        case .word: String(localized: "Word", table: "Vocabulary")
        case .expression: String(localized: "Expression", table: "Vocabulary")
        case .pattern: String(localized: "Pattern", table: "Vocabulary")
        case .sentence: String(localized: "Sentence", table: "Vocabulary")
        }
    }
}
