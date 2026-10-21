import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A normal document-like window, not another settings pane. The environment injects the same
/// store used by cards and the existing speech controller; this view owns only browsing state.
struct VocabularyNotebookView: View {
    @State private var restoreURL: URL?
    @ObservedObject var store: VocabularyStore
    let speech: LearningSpeechController
    var learning: VocabularyNotebookSession?
    var review: AnkiReviewController?
    @State private var selection: UUID?
    @State private var query = ""
    @State private var language: LearningLanguage?
    @State private var newestFirst = true
    @State private var editing: VocabularyEntry?
    @State private var deleting: VocabularySelection?
    @State private var requestedID: UUID?
    @State private var requestedSenseID: UUID?
    @State private var expandedEntries: Set<UUID> = []
    @State private var selectingForReview = false
    @State private var batchSelection: Set<VocabularySelection> = []
    @State private var showingBatch = false
    @State private var reviewError: String?

    init(store: VocabularyStore, speech: LearningSpeechController, selectedID: UUID? = nil, selectedSenseID: UUID? = nil,
         learning: VocabularyNotebookSession? = nil, review: AnkiReviewController? = nil) {
        self.store = store
        self.speech = speech
        self.learning = learning
        self.review = review
        let entry = store.entries.first { $0.id == selectedID }
        _selection = State(initialValue: selectedSenseID ?? entry?.senses.first?.id)
        _expandedEntries = State(initialValue: Set(entry.map { [$0.id] } ?? []))
        _requestedSenseID = State(initialValue: selectedSenseID)
        // A loaded archive already supplies the initial selection. Only a cold load needs
        // to retain the request; otherwise saving an annotation can replay it over browsing.
        _requestedID = State(initialValue: store.isLoaded ? nil : selectedID)
    }

    private var visibleEntries: [VocabularyEntry] {
        store.entries.filter { (language == nil || $0.language == language) && VocabularyPolicy.matches($0, query: query) }
            .sorted { newestFirst ? $0.updatedAt > $1.updatedAt : $0.updatedAt < $1.updatedAt }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(visibleEntries) { entry in
                    DisclosureGroup(isExpanded: Binding(get: { expandedEntries.contains(entry.id) }, set: { expanded in
                        if expanded { expandedEntries.insert(entry.id) } else { expandedEntries.remove(entry.id) }
                    })) {
                        ForEach(entry.senses) { sense in
                            HStack(alignment: .top) {
                              if selectingForReview {
                                Toggle("", isOn: Binding(get: {
                                    batchSelection.contains(.init(entryID: entry.id, senseID: sense.id))
                                }, set: { selected in
                                    let value = VocabularySelection(entryID: entry.id, senseID: sense.id)
                                    if selected { batchSelection.insert(value) } else { batchSelection.remove(value) }
                                })).labelsHidden().toggleStyle(.checkbox)
                                    .accessibilityLabel(entry.expression + " · " + sense.displayTitle)
                              }
                              VStack(alignment: .leading, spacing: 4) {
                                Text(sense.displayTitle).font(.callout).lineLimit(2)
                                Text(String(localized: "\(sense.examples.count) usages", table: "Vocabulary"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let example = sense.examples.first {
                                    Text(example.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }}.padding(.vertical, 4).tag(sense.id)
                        }
                    } label: { Text(entry.expression).font(.headline).lineLimit(2) }

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
            if let entry = selectedEntry, let sense = selectedSense {
                VocabularyEntryDetail(entry: entry, sense: sense, speech: speech, store: store, learning: learning, review: review,
                    edit: { editing = entry }, delete: { deleting = .init(entryID: entry.id, senseID: sense.id) },
                    newSense: {
                        Task { if let id = await store.createSense(entryID: entry.id) { selection = id } }
                    }, merge: { target in
                        Task {
                            if await store.mergeSenses(entryID: entry.id, source: sense.id, target: target) { selection = target }
                        }
                    })
                    .id(sense.id)
            } else {
                ContentUnavailableView(String(localized: "Vocabulary", table: "Vocabulary"), systemImage: "books.vertical")
            }
        }
        .searchable(text: $query, prompt: String(localized: "Search vocabulary", table: "Vocabulary"))
        .toolbar {
            if let review {
                ToolbarItem {
                    Button { selectingForReview.toggle() } label: { Image(systemName: "checklist") }
                        .help(String(localized: "Select senses for Anki", table: "Vocabulary"))
                }
                if selectingForReview {
                    ToolbarItem {
                        Button(String(localized: "Select visible", table: "Vocabulary")) {
                            batchSelection.formUnion(visibleEntries.flatMap { entry in
                                entry.senses.map { VocabularySelection(entryID: entry.id, senseID: $0.id) }
                            })
                        }
                    }
                    ToolbarItem {
                        Button(String(localized: "Prepare selected", table: "Vocabulary")) { showingBatch = true }
                            .disabled(batchSelection.isEmpty)
                    }
                }
                ToolbarItem {
                    Button { Task { reviewError = await review.reviewDeck() } } label: { Image(systemName: "rectangle.stack.badge.play") }
                        .help(String(localized: "Review in Anki", table: "Vocabulary"))
                }
            }
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
                Menu {
                    Button(String(localized: "Back up notebook…", table: "Vocabulary"), action: backup)
                    Button(String(localized: "Export data (JSON)…", table: "Vocabulary"), action: export)
                        .disabled(store.entries.isEmpty)
                    Divider()
                    Button(String(localized: "Restore notebook…", table: "Vocabulary"), action: chooseBackup)
                } label: { Image(systemName: "square.and.arrow.up") }
                    .help(String(localized: "Notebook backup", table: "Vocabulary"))
                    .disabled(!store.isLoaded)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { store.loadIfNeeded() }
        .onChange(of: selectedEntry, initial: true) { _, entry in learning?.select(entry, senseID: selection) }
        .onChange(of: selection) { _, _ in learning?.select(selectedEntry, senseID: selection) }
        .onChange(of: store.entries) { _, entries in
            if let requestedID, let entry = entries.first(where: { $0.id == requestedID }) {
                selection = requestedSenseID ?? entry.senses.first?.id
                expandedEntries.insert(entry.id)
                self.requestedID = nil; requestedSenseID = nil
            } else if let selection, let entry = entries.first(where: { VocabularySensePolicy.index(selection, in: $0) != nil }),
                      let index = VocabularySensePolicy.index(selection, in: entry) {
                self.selection = entry.senses[index].id
            } else if selection != nil { selection = nil }
        }
        .onChange(of: query) { _, value in
            if !value.isEmpty { expandedEntries.formUnion(visibleEntries.map(\.id)) }
        }
        .sheet(isPresented: $showingBatch) {
            if let review {
                VocabularyReviewBatchSheet(controller: review, selections: batchSelection.sorted {
                    $0.senseID.uuidString < $1.senseID.uuidString
                })
            }
        }
        .alert(String(localized: "Anki connection", table: "Vocabulary"), isPresented: Binding(
            get: { reviewError != nil }, set: { if !$0 { reviewError = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { reviewError = nil }
            } message: { Text(reviewError ?? "") }
        .sheet(item: $editing) { VocabularyEntryEditor(entry: $0, store: store, senseID: selection) }
        .alert(String(localized: "Replace notebook?", table: "Vocabulary"), isPresented: Binding(
            get: { restoreURL != nil }, set: { if !$0 { restoreURL = nil } })) {
                Button(String(localized: "Cancel"), role: .cancel) { restoreURL = nil }
                Button(String(localized: "Restore", table: "Vocabulary"), role: .destructive) {
                    if let url = restoreURL { Task { await store.restore(from: url) } }
                    restoreURL = nil
                }
            } message: { Text(String(localized: "Replace this notebook with the selected backup, including images and Anki associations.",
                table: "Vocabulary")) }
        .alert(String(localized: "Delete this sense?", table: "Vocabulary"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(String(localized: "Cancel"), role: .cancel) { deleting = nil }
                Button(String(localized: "Delete"), role: .destructive) {
                    if let target = deleting { Task { _ = await store.removeSense(entryID: target.entryID, senseID: target.senseID) } }
                    deleting = nil
                }
            }
        .alert(String(localized: "Vocabulary operation failed", table: "Vocabulary"), isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
    }

    private var selectedEntry: VocabularyEntry? {
        guard let selection else { return nil }
        return store.entries.first { VocabularySensePolicy.index(selection, in: $0) != nil }
    }
    private var selectedSense: VocabularySense? {
        guard let selection, let entry = selectedEntry, let index = VocabularySensePolicy.index(selection, in: entry) else { return nil }
        return entry.senses[index]
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

    private func backup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lingrove") ?? .data]
        panel.nameFieldStringValue = "Lingrove-vocabulary.lingrove"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await store.backup(to: url) }
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lingrove") ?? .data]
        panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK { restoreURL = panel.url } }
    }
}

/// Read-only browsing reuses the app's speech button and material cards. Edits are explicit sheets
/// so selecting another row cannot silently discard an in-progress note or sentence change.
private struct VocabularyEntryDetail: View {
    let entry: VocabularyEntry
    let sense: VocabularySense
    let speech: LearningSpeechController
    @ObservedObject var store: VocabularyStore
    var learning: VocabularyNotebookSession?
    var review: AnkiReviewController?
    let edit: () -> Void
    let delete: () -> Void
    let newSense: () -> Void
    let merge: (UUID) -> Void

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
                if let review { VocabularyReviewSection(entry: entry, sense: sense, controller: review) }
                if entry.dictionaryForm != entry.expression {
                    Text(entry.dictionaryForm).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if sense.isSavedWithoutContext {
                    if let learning {
                        VocabularyExplanationSection(entry: entry, sense: sense, store: store, learning: learning)
                    } else if !sense.meaning.isEmpty { Text(sense.meaning).textSelection(.enabled) }
                }
                if !sense.isSavedWithoutContext, !sense.meaning.isEmpty {
                    section(String(localized: "Core meaning", table: "Vocabulary")) { Text(sense.meaning).textSelection(.enabled) }
                }
                section(String(localized: "Sense explanation", table: "Vocabulary")) {
                    if let blocks = sense.content, !blocks.isEmpty {
                        VocabularyContentView(blocks: blocks, store: store)
                        Button(String(localized: "Edit", table: "Vocabulary"), action: edit).buttonStyle(.link)
                    } else {
                        Button(String(localized: "Add explanation", table: "Vocabulary"), action: edit).buttonStyle(.link)
                    }
                }
                ForEach(Array(sense.standaloneMeanings.filter {
                    !$0.text.isEmpty && $0.language != sense.meaningLanguage
                }.enumerated()), id: \.offset) { _, meaning in
                    VStack(alignment: .leading, spacing: 5) {
                        if let language = meaning.language { Text(language.label).font(.caption).foregroundStyle(.secondary) }
                        Text(meaning.text).textSelection(.enabled)
                    }
                }
                if !sense.alternateMeanings.isEmpty {
                    DisclosureGroup(String(localized: "Other wordings", table: "Vocabulary")) {
                        ForEach(Array(sense.alternateMeanings.enumerated()), id: \.offset) { _, wording in
                            Text(wording.text).font(.callout).textSelection(.enabled)
                        }
                    }
                }
                if !sense.tags.isEmpty { Text(sense.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                if !sense.note.isEmpty {
                    section(String(localized: "Notes", table: "Vocabulary")) { Text(sense.note).textSelection(.enabled) }
                }
                ForEach(sense.examples) { example in
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
                        ForEach(Array(example.translationVariants.filter {
                            $0.text != example.translation || $0.language != example.translationLanguage
                        }.enumerated()), id: \.offset) { _, variant in
                            Text(variant.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Menu(String(localized: "Move usage", table: "Vocabulary")) {
                            ForEach(entry.senses.filter { $0.id != sense.id }) { target in
                                Button(target.displayTitle) { move(example, to: target.id) }
                            }
                            Button(String(localized: "New sense", table: "Vocabulary")) { move(example, to: nil) }
                        }.menuStyle(.borderlessButton).fixedSize()
                        if let learning {
                            VocabularyExplanationSection(entry: entry, sense: sense, example: example, store: store, learning: learning)
                        } else if !example.meaning.isEmpty { Text(example.meaning).font(.callout).textSelection(.enabled) }
                        if let app = example.appBundleIdentifier,
                           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                            Text(FileManager.default.displayName(atPath: url.path))
                                .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                        }
                    }
                }
                if let learning { VocabularyDictionarySection(entry: entry, learning: learning) }
                Text(sense.createdAt, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.tertiary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(String(localized: "Edit", table: "Vocabulary"), action: edit)
                Button(action: newSense) { Image(systemName: "plus") }
                    .help(String(localized: "New sense", table: "Vocabulary"))
                Menu(String(localized: "Merge sense", table: "Vocabulary")) {
                    ForEach(entry.senses.filter { $0.id != sense.id }) { target in
                        Button(target.displayTitle) { merge(target.id) }
                    }
                }.disabled(entry.senses.count < 2)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.expression, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help(String(localized: "Copy expression", table: "Vocabulary"))
                Button(action: delete) { Image(systemName: "trash") }
                    .help(String(localized: "Delete", table: "Vocabulary"))
            }
        }
        .onDisappear { speech.stop(ownerID: sense.id) }
    }

    private func move(_ example: VocabularyExample, to target: UUID?) {
        Task { _ = await store.moveExample(entryID: entry.id, exampleID: example.id, source: sense.id, target: target) }
    }

    private func speaker(text: String, item: String, language: LearningLanguage) -> some View {
        LearningSpeechButton(speech: speech, request: SpeechRequest(target: SpeechTarget(ownerID: sense.id, itemID: "vocabulary." + item),
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

/// A label is a projection, never an identity or a semantic matching key. A contextual draft
/// can label an unnamed sense while its canonical summary remains explicitly editable.
extension VocabularySense {
    var displayTitle: String {
        if !meaning.isEmpty { return meaning }
        for block in content ?? [] {
            if case let .text(value) = block.content, !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.text
            }
        }
        if let text = examples.first(where: { !$0.meaning.isEmpty })?.meaning { return text }
        if !VocabularyContentPolicy.images(content ?? []).isEmpty { return String(localized: "Image explanation", table: "Vocabulary") }
        return String(localized: "Meaning pending", table: "Vocabulary")
    }
}
