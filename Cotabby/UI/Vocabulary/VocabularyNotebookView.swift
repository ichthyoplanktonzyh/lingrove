import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A normal document-like window, not another settings pane. The environment injects the same
/// store used by cards and the existing speech controller; this view owns only browsing state.
struct VocabularyNotebookView: View {
    @AppStorage private var browserMode: String
    @StateObject private var graph: VocabularyGraphPresentation
    @State private var selectedTag = ""
    @State private var restoreURL: URL?
    @ObservedObject var store: VocabularyStore
    let speech: LearningSpeechController
    var learning: VocabularyNotebookSession?
    var review: AnkiReviewController?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: UUID?
    @State private var query = ""
    @State private var language: LearningLanguage?
    @State private var newestFirst = true
    @State private var editing: VocabularyEntry?
    @State private var deleting: VocabularySelection?
    @State private var requestedID: UUID?
    @State private var requestedSenseID: UUID?
    @State private var expandedEntries: Set<UUID> = []
    @State private var selectingSenses = false
    @State private var batchSelection: Set<VocabularySelection> = []
    @State private var showingBatch = false
    @State private var exporting: VocabularyExportRequest?
    @State private var reviewError: String?

    init(store: VocabularyStore, speech: LearningSpeechController, selectedID: UUID? = nil, selectedSenseID: UUID? = nil,
         learning: VocabularyNotebookSession? = nil, review: AnkiReviewController? = nil,
         preferences: UserDefaults = .standard) {
        _browserMode = AppStorage(wrappedValue: "list", "vocabularyBrowserMode", store: preferences)
        _graph = StateObject(wrappedValue: VocabularyGraphPresentation(defaults: preferences))
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
        store.entries.compactMap { entry -> VocabularyEntry? in
            guard language == nil || entry.language == language else { return nil }
            var value = entry
            if !selectedTag.isEmpty { value.senses.removeAll { !$0.tags.contains(selectedTag) } }
            return !value.senses.isEmpty && VocabularyPolicy.matches(value, query: query) ? value : nil
        }.sorted { newestFirst ? $0.updatedAt > $1.updatedAt : $0.updatedAt < $1.updatedAt }
    }

    private var allTags: [String] {
        Array(Set(store.entries.flatMap { $0.senses.flatMap(\.tags) })).sorted()
    }

    private var graphSelection: VocabularySelection? {
        guard let entry = selectedEntry, let sense = selectedSense else { return nil }
        return .init(entryID: entry.id, senseID: sense.id)
    }

    var body: some View {
        Group {
            if browserMode == "graph" {
                graphBrowser
            } else { listBrowser }
        }
        .searchable(text: $query, prompt: String(localized: "Search vocabulary", table: "Vocabulary"))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(String(localized: "Browse vocabulary", table: "Vocabulary"), selection: $browserMode) {
                    Text(String(localized: "List", table: "Vocabulary")).tag("list")
                    Text(String(localized: "Graph", table: "Vocabulary")).tag("graph")
                }.pickerStyle(.segmented).frame(width: 150)
            }
            ToolbarItemGroup {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.94)) {
                        selectingSenses.toggle()
                        if selectingSenses { browserMode = "list" }
                    }
                } label: {
                    Image(systemName: selectingSenses ? "checklist.checked" : "checklist")
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(String(localized: "Select senses", table: "Vocabulary"))

                if let review {
                    Button { Task { reviewError = await review.reviewDeck() } } label: { Image(systemName: "rectangle.stack.badge.play") }
                        .help(String(localized: "Review in Anki", table: "Vocabulary"))
                }
                if browserMode == "graph" {
                    if !allTags.isEmpty {
                        Picker(String(localized: "Tags", table: "Vocabulary"), selection: $selectedTag) {
                            Text(String(localized: "All tags", table: "Vocabulary")).tag("")
                            ForEach(allTags, id: \.self) { Text($0).tag($0) }
                        }.frame(maxWidth: 120)
                    }
                    Picker(String(localized: "Language", table: "Vocabulary"), selection: $language) {
                        Text(String(localized: "All languages", table: "Vocabulary")).tag(nil as LearningLanguage?)
                        ForEach(LearningLanguage.allCases) { Text($0.label).tag(Optional($0)) }
                    }.frame(maxWidth: 140)
                }
                Menu {
                    Button(String(localized: "Export…", table: "Vocabulary")) { beginExport() }
                        .disabled(store.entries.isEmpty)
                    Button(String(localized: "Full notebook backup…", table: "Vocabulary"), action: backup)
                    Divider()
                    Button(String(localized: "Restore notebook…", table: "Vocabulary"), action: chooseBackup)
                } label: { Image(systemName: "square.and.arrow.up") }
                    .help(String(localized: "Export and backup", table: "Vocabulary"))
                    .disabled(!store.isLoaded)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { store.loadIfNeeded(); if browserMode == "graph" { graph.reveal(graphSelection) } }
        .onChange(of: selectedEntry, initial: true) { _, entry in learning?.select(entry, senseID: selection) }
        .onChange(of: selection) { _, _ in
            learning?.select(selectedEntry, senseID: selection)
            if browserMode == "graph" { graph.reveal(graphSelection) }
        }
        .onChange(of: browserMode) { _, value in if value == "graph" { graph.reveal(graphSelection) } }
        .onChange(of: store.entries) { _, entries in
            if !selectedTag.isEmpty, !entries.contains(where: { $0.senses.contains { $0.tags.contains(selectedTag) } }) {
                selectedTag = ""
            }
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
            reconcileGraphSelection()
        }
        .onChange(of: selectedTag) { _, _ in reconcileGraphSelection() }
        .onChange(of: language) { _, _ in reconcileGraphSelection() }
        .sheet(item: $exporting) { request in VocabularyExportSheet(store: store, request: request) }
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

    private func reconcileGraphSelection() {
        guard browserMode == "graph", let selection else { return }
        if !visibleEntries.contains(where: { VocabularySensePolicy.index(selection, in: $0) != nil }) {
            self.selection = nil
            graph.clearFocus()
        }
    }

    private var graphBrowser: some View {
        let drawerWidth: CGFloat = 396
        let hasSelection = selectedSense != nil
        return ZStack(alignment: .trailing) {
            VocabularyGraphView(
                entries: visibleEntries,
                query: query,
                selection: graphSelection,
                presentation: graph,
                select: { next in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.92)) {
                        selection = next?.senseID
                    }
                },
                trailingInset: hasSelection ? (drawerWidth + 16) : 0
            )
            .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)

            if hasSelection {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Label(
                            selectedEntry?.expression ?? String(localized: "Core meaning", table: "Vocabulary"),
                            systemImage: "sparkles.rectangle.stack"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        Spacer()
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.94)) {
                                selection = nil
                                graph.clearFocus()
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Close details", table: "Vocabulary"))
                        .accessibilityLabel(String(localized: "Close details", table: "Vocabulary"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider().opacity(0.6)
                    entryDetail
                }
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.14), radius: 18, x: -4, y: 4)
                .padding(12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.92), value: hasSelection)
    }

    private var listBrowser: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(visibleEntries) { entry in
                    if entry.senses.count == 1, let singleSense = entry.senses.first {
                        HStack(alignment: .top, spacing: 8) {
                            if selectingSenses {
                                senseCheckbox(entry: entry, sense: singleSense)
                                    .padding(.top, 2)
                            }
                            VocabularySingleEntryRow(entry: entry, sense: singleSense)
                        }
                        .padding(.vertical, 4)
                        .tag(singleSense.id)
                        .contextMenu {
                            Button(String(localized: "Export this sense…", table: "Vocabulary")) {
                                beginExport(single: .init(entryID: entry.id, senseID: singleSense.id))
                            }
                        }
                    } else {
                        DisclosureGroup(isExpanded: Binding(get: { expandedEntries.contains(entry.id) }, set: { expanded in
                            if expanded { expandedEntries.insert(entry.id) } else { expandedEntries.remove(entry.id) }
                        })) {
                            ForEach(entry.senses) { sense in
                                HStack(alignment: .top, spacing: 8) {
                                    if selectingSenses {
                                        senseCheckbox(entry: entry, sense: sense)
                                            .padding(.top, 2)
                                    }
                                    VocabularySenseSummary(sense: sense)
                                }
                                .padding(.vertical, 4)
                                .tag(sense.id)
                                .contextMenu {
                                    Button(String(localized: "Export this sense…", table: "Vocabulary")) {
                                        beginExport(single: .init(entryID: entry.id, senseID: sense.id))
                                    }
                                }
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(entry.expression)
                                    .font(.headline)
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                Text(entry.language.compactLabel)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                                Text("\(entry.senses.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(CotabbyBrand.accent)
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 1)
                                    .background(Capsule(style: .continuous).fill(CotabbyBrand.accent.opacity(0.12)))
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                sidebarFilterBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selectingSenses {
                    floatingBatchBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if visibleEntries.isEmpty {
                    ContentUnavailableView(query.isEmpty && language == nil && selectedTag.isEmpty
                        ? String(localized: "No saved expressions", table: "Vocabulary")
                        : String(localized: "No matching expressions", table: "Vocabulary"), systemImage: "books.vertical")
                }
            }
            .navigationSplitViewColumnWidth(min: 245, ideal: 300, max: 420)
        } detail: {
            entryDetail
        }
    }

    private func senseCheckbox(entry: VocabularyEntry, sense: VocabularySense) -> some View {
        Toggle("", isOn: Binding(get: {
            batchSelection.contains(.init(entryID: entry.id, senseID: sense.id))
        }, set: { selected in
            let value = VocabularySelection(entryID: entry.id, senseID: sense.id)
            if selected { batchSelection.insert(value) } else { batchSelection.remove(value) }
        }))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .accessibilityLabel(entry.expression + " · " + sense.displayTitle)
    }

    /// Compact filter strip anchored above the sidebar list. Keeping language, tag, and sort
    /// controls inside the sidebar eliminates main-toolbar clutter and visually ties filters to
    /// the list they govern.
    private var sidebarFilterBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    language = nil
                } label: {
                    HStack {
                        Text(String(localized: "All languages", table: "Vocabulary"))
                        if language == nil { Image(systemName: "checkmark") }
                    }
                }
                Divider()
                ForEach(LearningLanguage.allCases) { item in
                    Button {
                        language = item
                    } label: {
                        HStack {
                            Text(item.label)
                            if language == item { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                filterPillLabel(
                    title: language?.compactLabel ?? String(localized: "All languages", table: "Vocabulary"),
                    symbol: "globe",
                    isActive: language != nil
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if !allTags.isEmpty {
                Menu {
                    Button {
                        selectedTag = ""
                    } label: {
                        HStack {
                            Text(String(localized: "All tags", table: "Vocabulary"))
                            if selectedTag.isEmpty { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(allTags, id: \.self) { tag in
                        Button {
                            selectedTag = tag
                        } label: {
                            HStack {
                                Text(tag)
                                if selectedTag == tag { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    filterPillLabel(
                        title: selectedTag.isEmpty ? String(localized: "All tags", table: "Vocabulary") : "#\(selectedTag)",
                        symbol: "tag",
                        isActive: !selectedTag.isEmpty
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if language != nil || !selectedTag.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        language = nil
                        selectedTag = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear filters", table: "Vocabulary"))
            }

            Spacer(minLength: 4)

            Text("\(visibleEntries.count)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 1.0)) {
                    newestFirst.toggle()
                }
            } label: {
                Image(systemName: newestFirst ? "arrow.down.circle" : "arrow.up.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(newestFirst
                ? String(localized: "Newest first", table: "Vocabulary")
                : String(localized: "Oldest first", table: "Vocabulary"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private func filterPillLabel(title: String, symbol: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(isActive ? CotabbyBrand.accent : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            Capsule(style: .continuous)
                .fill(isActive ? CotabbyBrand.accent.opacity(0.12) : Color.primary.opacity(0.055))
        )
    }

    /// Translucent bottom bar that slides in during multi-select mode, replacing the old toolbar
    /// items that caused layout shifts across the window chrome.
    private var floatingBatchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("\(batchSelection.count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(CotabbyBrand.accent))
                Button(String(localized: "Select visible", table: "Vocabulary")) {
                    batchSelection.formUnion(selections(in: visibleEntries))
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.link)
                if !batchSelection.isEmpty {
                    Button(String(localized: "Clear", table: "Vocabulary")) {
                        batchSelection.removeAll()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.95)) {
                        selectingSenses = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Button {
                    beginExport(scope: .selected)
                } label: {
                    Label(String(localized: "Export selected…", table: "Vocabulary"), systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(batchSelection.isEmpty)

                if review != nil {
                    Button {
                        showingBatch = true
                    } label: {
                        Label(String(localized: "Prepare selected", table: "Vocabulary"), systemImage: "rectangle.stack.badge.plus")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(batchSelection.isEmpty)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(10)
    }

    @ViewBuilder private var entryDetail: some View {
        if let entry = selectedEntry, let sense = selectedSense {
            VocabularyEntryDetail(entry: entry, sense: sense, speech: speech, store: store, learning: learning, review: review,
                edit: { editing = entry }, delete: { deleting = .init(entryID: entry.id, senseID: sense.id) },
                newSense: {
                    Task { if let id = await store.createSense(entryID: entry.id) { selection = id } }
                }, merge: { target in
                    Task {
                        if await store.mergeSenses(entryID: entry.id, source: sense.id, target: target) { selection = target }
                    }
                }, selectSense: { id in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1.0)) {
                        selection = id
                    }
                }, filterByTag: { tag in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        selectedTag = selectedTag == tag ? "" : tag
                    }
                })
                .id(sense.id)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: sense.id)
        } else {
            ContentUnavailableView(String(localized: "Vocabulary", table: "Vocabulary"), systemImage: "books.vertical")
        }
    }

    private var selectedEntry: VocabularyEntry? {
        guard let selection else { return nil }
        return store.entries.first { VocabularySensePolicy.index(selection, in: $0) != nil }
    }
    private var selectedSense: VocabularySense? {
        guard let selection, let entry = selectedEntry, let index = VocabularySensePolicy.index(selection, in: entry) else { return nil }
        return entry.senses[index]
    }

    private func selections(in entries: [VocabularyEntry]) -> [VocabularySelection] {
        entries.flatMap { entry in entry.senses.map { .init(entryID: entry.id, senseID: $0.id) } }
    }

    private func beginExport(scope: VocabularyExportScope? = nil, single: VocabularySelection? = nil) {
        let all = selections(in: store.entries.sorted { newestFirst ? $0.updatedAt > $1.updatedAt : $0.updatedAt < $1.updatedAt })
        let selected = single.map { [$0] } ?? all.filter { batchSelection.contains($0) }
        let initial = single != nil ? VocabularyExportScope.selected : scope ?? (!selected.isEmpty ? .selected :
            query.isEmpty && language == nil && selectedTag.isEmpty ? .all : .filtered)
        exporting = .init(all: all, filtered: selections(in: visibleEntries), selected: selected, initialScope: initial)
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

/// Editorial reading view for a single vocabulary sense. Typography and spacing establish
/// hierarchy: the headword and core meaning read directly on the page like a classic dictionary,
/// while contextual usage examples, AI explanations, and Anki review cards occupy distinct
/// elevated containers.
struct VocabularyEntryDetail: View {
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
    var selectSense: ((UUID) -> Void)?
    var filterByTag: ((String) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroHeader
                if entry.senses.count > 1 {
                    senseSwitcherBar
                }
                coreMeaningSection
                senseExplanationAndNotesSection
                if !sense.examples.isEmpty {
                    examplesSection
                }
                if let review {
                    VocabularyReviewSection(entry: entry, sense: sense, controller: review)
                }
                if let learning {
                    VocabularyDictionarySection(entry: entry, learning: learning)
                }
                footerMetadata
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Button(action: delete) { Image(systemName: "trash") }
                    .help(String(localized: "Delete", table: "Vocabulary"))
            }
        }
        .onDisappear { speech.stop(ownerID: sense.id) }
    }

    /// Editorial headword block with inline audio playback, tactile copy confirmation, and
    /// metadata pills (language, entry kind, lemma, and clickable tags).
    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.expression)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.3)
                    .textSelection(.enabled)
                speaker(text: entry.expression, item: "expression", language: entry.language)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Spacer(minLength: 8)
                VocabularyCopyActionButton(
                    title: String(localized: "Copy expression", table: "Vocabulary"),
                    text: entry.expression
                )
                Button(action: edit) {
                    Label(String(localized: "Edit", table: "Vocabulary"), systemImage: "pencil")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                VocabularyFavoriteIcon(isSaved: true)
                    .frame(width: 18, height: 18)
            }

            HStack(spacing: 6) {
                metadataBadge(entry.language.label, tint: CotabbyBrand.accent)
                metadataBadge(entry.kind.label, tint: .secondary)
                if entry.dictionaryForm != entry.expression {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(entry.dictionaryForm)
                            .font(.caption.weight(.medium))
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.045)))
                }
                ForEach(sense.tags, id: \.self) { tag in
                    Button {
                        filterByTag?(tag)
                    } label: {
                        Text("#" + tag)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(CotabbyBrand.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(CotabbyBrand.accent.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func metadataBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(tint == .secondary ? Color.primary.opacity(0.06) : tint.opacity(0.11))
            )
    }

    /// Horizontal pill bar shown when an entry has multiple senses, allowing instant sense
    /// switching right inside the detail pane without hunting in the sidebar tree.
    private var senseSwitcherBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(entry.senses.enumerated()), id: \.element.id) { index, item in
                    let isSelected = item.id == sense.id
                    Button {
                        selectSense?(item.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? .white : .secondary)
                                .frame(width: 16, height: 16)
                                .background(
                                    Circle().fill(isSelected ? CotabbyBrand.accent : Color.primary.opacity(0.08))
                                )
                            Text(item.displayTitle)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 5)
                        .padding(.trailing, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? CotabbyBrand.accent.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(isSelected ? CotabbyBrand.accent.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Button(action: newSense) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help(String(localized: "New sense", table: "Vocabulary"))
            }
        }
    }

    /// Unboxed editorial core definition block. When saved without context, integrates the
    /// general AI explanation inline; when saved with context, highlights the core meaning with
    /// strong typographic presence.
    @ViewBuilder
    private var coreMeaningSection: some View {
        let otherMeanings = sense.standaloneMeanings.filter { !$0.text.isEmpty && $0.language != sense.meaningLanguage }
        if sense.isSavedWithoutContext || !sense.meaning.isEmpty || !otherMeanings.isEmpty || !sense.alternateMeanings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !sense.isSavedWithoutContext, !sense.meaning.isEmpty {
                    Text(sense.meaning)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if sense.isSavedWithoutContext {
                    if let learning {
                        VocabularyExplanationSection(entry: entry, sense: sense, store: store, learning: learning)
                    } else if !sense.meaning.isEmpty {
                        Text(sense.meaning)
                            .font(.system(size: 17, weight: .semibold))
                            .textSelection(.enabled)
                    }
                }
                ForEach(Array(otherMeanings.enumerated()), id: \.offset) { _, meaning in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let language = meaning.language {
                            Text(language.compactLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                        }
                        Text(meaning.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
                if !sense.alternateMeanings.isEmpty {
                    DisclosureGroup(String(localized: "Other wordings", table: "Vocabulary")) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(sense.alternateMeanings.enumerated()), id: \.offset) { _, wording in
                                Text(wording.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Combines user-authored rich content blocks and personal notes into a cohesive editorial
    /// callout card. When neither exists yet, presents a quiet inline prompt instead of two
    /// empty gray boxes.
    @ViewBuilder
    private var senseExplanationAndNotesSection: some View {
        let hasBlocks = !(sense.content ?? []).isEmpty
        let hasNote = !sense.note.isEmpty
        if hasBlocks || hasNote {
            VStack(alignment: .leading, spacing: 14) {
                if let blocks = sense.content, !blocks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(String(localized: "Sense explanation", table: "Vocabulary"), systemImage: "text.book.closed")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "Edit", table: "Vocabulary"), action: edit)
                                .font(.caption.weight(.medium))
                                .buttonStyle(.link)
                        }
                        VocabularyContentView(blocks: blocks, store: store)
                    }
                }
                if hasBlocks && hasNote {
                    Divider().opacity(0.5)
                }
                if hasNote {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(String(localized: "Notes", table: "Vocabulary"), systemImage: "note.text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(sense.note)
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.9))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5)
            )
        } else {
            Button(action: edit) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.caption.weight(.semibold))
                    Text(String(localized: "Add explanation", table: "Vocabulary"))
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sense.examples) { example in
                VocabularyExampleCard(
                    entry: entry,
                    sense: sense,
                    example: example,
                    speech: speech,
                    store: store,
                    learning: learning,
                    move: { target in move(example, to: target) }
                )
            }
        }
    }

    private var footerMetadata: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.caption2)
            Text(sense.createdAt, format: .dateTime.year().month().day())
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }

    private func move(_ example: VocabularyExample, to target: UUID?) {
        Task { _ = await store.moveExample(entryID: entry.id, exampleID: example.id, source: sense.id, target: target) }
    }

    private func speaker(text: String, item: String, language: LearningLanguage) -> some View {
        LearningSpeechButton(speech: speech, request: SpeechRequest(target: SpeechTarget(ownerID: sense.id, itemID: "vocabulary." + item),
            text: text, language: language), playLabel: String(localized: "Read aloud", table: "Vocabulary"),
            stopLabel: String(localized: "Stop reading", table: "Vocabulary"))
    }
}

/// Elevated card for one encountered usage example. Highlights the target expression with a soft
/// accent marker tint, pairs source and translation with inline TTS buttons, and reveals the
/// "Move usage" menu on hover or VoiceOver focus to keep reading uncluttered.
private struct VocabularyExampleCard: View {
    let entry: VocabularyEntry
    let sense: VocabularySense
    let example: VocabularyExample
    let speech: LearningSpeechController
    @ObservedObject var store: VocabularyStore
    var learning: VocabularyNotebookSession?
    let move: (UUID?) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: example.completeness == .sentence ? "quote.opening" : "text.quote")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CotabbyBrand.accent)
                Text(example.completeness == .sentence
                    ? String(localized: "Example sentence", table: "Vocabulary")
                    : String(localized: "Context fragment", table: "Vocabulary"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(entry.senses.filter { $0.id != sense.id }) { target in
                        Button(target.displayTitle) { move(target.id) }
                    }
                    Button(String(localized: "New sense", table: "Vocabulary")) { move(nil) }
                } label: {
                    Text(String(localized: "Move usage", table: "Vocabulary"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .opacity(hovering ? 1.0 : 0.45)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Text(highlighted(example))
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    speaker(text: example.text, item: example.id.uuidString, language: entry.language)
                }
                if !example.translation.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Text(example.translation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        speaker(text: example.translation, item: example.id.uuidString + ".translation",
                            language: example.translationLanguage ?? entry.language)
                    }
                }
                ForEach(Array(example.translationVariants.filter {
                    $0.text != example.translation || $0.language != example.translationLanguage
                }.enumerated()), id: \.offset) { _, variant in
                    Text(variant.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let learning {
                VocabularyExplanationSection(entry: entry, sense: sense, example: example, store: store, learning: learning)
            } else if !example.meaning.isEmpty {
                Text(example.meaning)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
            }

            if let app = example.appBundleIdentifier,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                HStack(spacing: 5) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                    Text(FileManager.default.displayName(atPath: url.path))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.032))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovering ? 0.13 : 0.08), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
    }

    private func speaker(text: String, item: String, language: LearningLanguage) -> some View {
        LearningSpeechButton(speech: speech, request: SpeechRequest(target: SpeechTarget(ownerID: sense.id, itemID: "vocabulary." + item),
            text: text, language: language), playLabel: String(localized: "Read aloud", table: "Vocabulary"),
            stopLabel: String(localized: "Stop reading", table: "Vocabulary"))
    }

    private func highlighted(_ example: VocabularyExample) -> AttributedString {
        var result = AttributedString(example.text)
        for value in example.ranges {
            guard VocabularyPolicy.valid(value.nsRange, in: example.text), let range = Range(value.nsRange, in: example.text),
                  let converted = Range(range, in: result) else { continue }
            result[converted].font = .system(size: 15, weight: .semibold)
            result[converted].foregroundColor = CotabbyBrand.accent
            result[converted].backgroundColor = CotabbyBrand.accent.opacity(0.11)
        }
        return result
    }
}

/// Tactile copy pill button for the detail header. Confirms clipboard action with a spring-animated
/// green checkmark before returning to rest.
private struct VocabularyCopyActionButton: View {
    let title: String
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            resetTask?.cancel()
            withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.9)) {
                didCopy = true
            }
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    didCopy = false
                }
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(didCopy ? Color.green : (hovering ? Color.primary : Color.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(LearningIconActionButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .onDisappear { resetTask?.cancel() }
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

/// Flat, scannable sidebar row for the common single-sense entry case. Clicking selects the
/// sense directly without requiring a disclosure-triangle expansion first.
private struct VocabularySingleEntryRow: View {
    let entry: VocabularyEntry
    let sense: VocabularySense

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.expression)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !(sense.reviewCards ?? []).isEmpty {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Text(entry.language.compactLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            Text(sense.displayTitle)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)
            if let example = sense.examples.first {
                Text(example.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !sense.tags.isEmpty {
                Text(sense.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The notebook list and its Home walkthrough share the exact sense label. Selection remains
/// the host's responsibility; this value-only component never edits or reclassifies a usage.
struct VocabularySenseSummary: View {
    let sense: VocabularySense
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sense.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(String(localized: "\(sense.examples.count) usages", table: "Vocabulary"))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            if let example = sense.examples.first {
                Text(example.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !sense.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(sense.tags.prefix(3), id: \.self) { tag in
                        Text("#" + tag)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.05)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("生词本 · 列表与详情") {
    let store = VocabularyStore(archive: VocabularyArchive(url: nil))
    let speech = LearningSpeechController(settings: LearningSpeechSettings())
    VocabularyNotebookView(store: store, speech: speech, learning: nil)
        .frame(width: 960, height: 640)
}
#endif
