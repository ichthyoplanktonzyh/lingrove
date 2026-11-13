import LingroveNotebook
import LingroveNotebookEngine
import LingroveStudyExport
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A normal document-like window, not another settings pane. The environment injects the same
/// store used by cards and the existing speech controller; this view owns only browsing state.
struct VocabularyNotebookView: View {
    @AppStorage private var browserMode: String
    @AppStorage private var organization: String
    @AppStorage private var listDensity: String
    @AppStorage private var textSizeRaw: String
    @AppStorage private var showsUnexplored: Bool
    @StateObject private var graph: VocabularyGraphPresentation
    @StateObject private var browser = VocabularyBrowserCache()
    @State private var selectedTag = ""
    @State private var restoreURL: URL?
    @ObservedObject var store: VocabularyStore
    let speech: LearningSpeechController
    var learning: VocabularyNotebookSession?
    var review: AnkiReviewController?
    var builtInReview: BuiltInReviewSession?
    var search: VocabularySearchController?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vocabularyMeaningLanguages) private var meaningLanguages
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
    @State private var creatingEntry = false
    @State private var addedSelection: VocabularySelection?
    @State private var meaningDestination: VocabularyMeaningDestination?
    @State private var creatingMeaning = false

    init(store: VocabularyStore, speech: LearningSpeechController, selectedID: UUID? = nil, selectedSenseID: UUID? = nil,
         learning: VocabularyNotebookSession? = nil, review: AnkiReviewController? = nil,
         builtInReview: BuiltInReviewSession? = nil, search: VocabularySearchController? = nil,
         preferences: UserDefaults = .standard) {
        _browserMode = AppStorage(wrappedValue: "list", "vocabularyBrowserMode", store: preferences)
        _organization = AppStorage(wrappedValue: "entry", "vocabularyOrganization", store: preferences)
        _listDensity = AppStorage(wrappedValue: "compact", "vocabularyListDensity", store: preferences)
        _textSizeRaw = AppStorage(wrappedValue: VocabularyTextSize.standard.rawValue, "vocabularyTextSize", store: preferences)
        _showsUnexplored = AppStorage(wrappedValue: false, "vocabularyShowsUnexplored", store: preferences)
        _graph = StateObject(wrappedValue: VocabularyGraphPresentation(defaults: preferences))
        self.store = store
        self.speech = speech
        self.learning = learning
        self.review = review
        self.builtInReview = builtInReview
        self.search = search
        let entry = store.entries.first { $0.id == selectedID }
        _selection = State(initialValue: selectedSenseID ?? entry?.defaultSense?.id)
        _expandedEntries = State(initialValue: Set(entry.map { [$0.id] } ?? []))
        _requestedSenseID = State(initialValue: selectedSenseID)
        if let selectedID {
            _meaningDestination = State(initialValue: .sense(nodeID: nil,
                senseID: selectedSenseID ?? entry?.defaultSense?.id ?? selectedID))
        }
        // A loaded archive already supplies the initial selection. Only a cold load needs
        // to retain the request; otherwise saving an annotation can replay it over browsing.
        _requestedID = State(initialValue: store.isLoaded ? nil : selectedID)
    }

    private var scopedEntries: [VocabularyEntry] {
        browser.entries(store: store, language: language, tag: selectedTag, newestFirst: newestFirst)
    }

    private var browseQuery: NotebookBrowseQuery { .init(language: language, tag: selectedTag, newestFirst: newestFirst) }
    private var usesPagedEntries: Bool {
        organization == "entry" && browserMode == "list"
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectingSenses
    }
    private func prepareBrowser() {
        if usesPagedEntries { store.browse(browseQuery) } else {
            store.browsing?.deactivate(); store.loadIfNeeded()
            if !query.isEmpty {
                let identity = store.scopeIdentity
                Task {
                    await store.load()
                    guard identity == store.scopeIdentity, store.isLoaded else { return }
                    search?.activate()
                }
            }
        }
    }

    private var visibleEntries: [VocabularyEntry] {
        let scoped = scopedEntries
        return organization == "meaning" ? scoped : browser.matching(scoped, query: query)
    }
    @ViewBuilder private var collectionCount: some View {
        if let search, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VocabularySearchCountView(controller: search)
        } else {
            Text("\(usesPagedEntries ? store.browsing?.total ?? 0 : organization == "meaning" ? meaningItems.count : visibleEntries.count)")
        }
    }
    private var meaningItems: [VocabularyMeaningBrowserProjection.Item] {
        browser.meanings(store: store, entries: scopedEntries, query: query,
            includeEmpty: language == nil && selectedTag.isEmpty, languages: meaningLanguages)
    }
    private var unclassified: [VocabularySelection] {
        browser.unclassified(store: store, entries: scopedEntries, query: query)
    }
    private var activeSenseID: UUID? { organization == "meaning" ? meaningDestination?.senseID : selection }
    private var selectedMeaning: VocabularyMeaningNode? {
        guard organization == "meaning", case let .node(id) = meaningDestination else { return nil }
        return store.semantics.nodes.first { $0.id == id }
    }
    private var selectedCategory: VocabularyCategory? {
        guard organization == "meaning", let id = meaningDestination?.categoryID else { return nil }
        return store.classification.categories.first { $0.id == id && !$0.isRetired }
    }
    private func categoryAncestors(forMeaning id: UUID) -> Set<UUID> {
        Set(store.classification.memberships
            .filter { $0.nodeID == id && $0.provenance.status == .confirmed }
            .flatMap { VocabularyClassificationPolicy.ancestors(of: $0.categoryID, in: store.classification) })
    }
    private func showCategory(_ id: UUID) {
        let ancestors = VocabularyClassificationPolicy.ancestors(of: id, in: store.classification)
        organization = "meaning"
        meaningDestination = .category(id)
        graph.revealCategory(id, ancestors: ancestors)
    }
    private func showMeaning(_ id: UUID) {
        organization = "meaning"
        meaningDestination = .node(id)
        graph.revealMeaning(id, ancestors: categoryAncestors(forMeaning: id))
    }
    private func showSense(_ id: UUID) {
        if organization == "meaning" {
            meaningDestination = .sense(nodeID: meaningDestination?.nodeID, senseID: id)
        } else { selection = id }
    }

    private var allTags: [String] {
        store.isLoaded ? store.readIndex.allTags : store.browsing?.tags ?? []
    }

    private var graphSelection: VocabularySelection? {
        guard let entry = selectedEntry, let sense = selectedSense else { return nil }
        return .init(entryID: entry.id, senseID: sense.id)
    }

    private var animatedBrowserMode: Binding<String> {
        Binding(
            get: { browserMode },
            set: { next in
                guard next != browserMode else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.92)) {
                    browserMode = next
                    if next == "graph" {
                        selectingSenses = false
                    }
                }
            }
        )
    }

    private var browserContent: some View {
        ZStack {
            if !store.isAvailable {
                ContentUnavailableView {
                    Label(String(localized: "Vocabulary", table: "Vocabulary"), systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(String(localized: "The notebook is unavailable. Your original data has been preserved.", table: "Vocabulary"))
                }
            } else if usesPagedEntries {
                if store.browsing?.isReady == true, store.browsing?.total == 0, language == nil, selectedTag.isEmpty {
                    emptyNotebookContent
                } else { pagedListBrowser }
            } else if !store.isLoaded && store.entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let search, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NavigationSplitView {
                    VStack(spacing: 0) {
                        sidebarFilterBar
                        VocabularySearchResultsView(controller: search, query: query, language: language, tag: selectedTag,
                            selectedSenseID: activeSenseID, onSelect: { senseID, nodeID in
                                if organization == "meaning" {
                                    meaningDestination = .sense(nodeID: nodeID, senseID: senseID)
                                } else {
                                    showSense(senseID)
                                }
                            }, senseMenu: senseContextMenu)
                    }
                    .navigationSplitViewColumnWidth(min: 260, ideal: 315, max: 420)
                } detail: { browserDetail }
            } else if store.isLoaded && store.entries.isEmpty && organization == "entry" {
                emptyNotebookContent
            } else if browserMode == "graph" {
                graphBrowser
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.975)),
                                removal: .opacity.combined(with: .scale(scale: 0.985))
                            )
                    )
            } else {
                Group { if organization == "meaning" { meaningListBrowser } else { listBrowser } }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 1.012)),
                                removal: .opacity.combined(with: .scale(scale: 0.988))
                            )
                    )
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.92), value: browserMode)
        .searchable(text: $query, prompt: search != nil || organization == "meaning"
            ? String(localized: "Search an idea or expression", table: "Vocabulary")
            : String(localized: "Search vocabulary", table: "Vocabulary"))
        .searchSuggestions {
            // Installation belongs to the search interaction. SwiftUI presents this content
            // only while the native search field is active, leaving ordinary browsing unchanged.
            if let search { VocabularySearchSuggestionsView(controller: search) }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(String(localized: "Browse vocabulary", table: "Vocabulary"), selection: animatedBrowserMode) {
                    Label(String(localized: "List", table: "Vocabulary"), systemImage: "list.bullet").tag("list")
                    Label(String(localized: "Graph", table: "Vocabulary"), systemImage: "point.3.connected.trianglepath.dotted")
                        .tag("graph")
                }
                .pickerStyle(.segmented)
                .frame(width: 164)
            }
            ToolbarItemGroup {
                Button { creatingEntry = true } label: {
                    Label(String(localized: "Add entry", table: "Vocabulary"), systemImage: "plus")
                }
                .help(String(localized: "Add entry", table: "Vocabulary"))
                .accessibilityIdentifier("vocabularyAddEntry")
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!store.isLoaded && store.browsing?.isReady != true)

                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.94)) {
                        selectingSenses.toggle()
                        if selectingSenses { browserMode = "list"; organization = "entry" }
                    }
                } label: {
                    Image(systemName: selectingSenses ? "checklist.checked" : "checklist")
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(String(localized: "Select senses", table: "Vocabulary"))

                Menu {
                    Picker(String(localized: "Text size", table: "Vocabulary"), selection: $textSizeRaw) {
                        ForEach(VocabularyTextSize.allCases) { level in
                            Text(level.label).tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button(String(localized: "Larger text", table: "Vocabulary")) {
                        textSizeRaw = currentTextSize.larger.rawValue
                    }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(currentTextSize == .extraLarge)
                    Button(String(localized: "Smaller text", table: "Vocabulary")) {
                        textSizeRaw = currentTextSize.smaller.rawValue
                    }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(currentTextSize == .small)
                } label: {
                    Image(systemName: "textformat.size")
                }
                .help(String(localized: "Text size", table: "Vocabulary"))
                .accessibilityIdentifier("vocabularyTextSize")

                Menu {
                    if let search, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VocabularySearchExportAction(controller: search, query: query, revision: store.contentRevision) { beginExport() }
                    } else {
                        Button { beginExport() } label: {
                            Label(String(localized: "Export…", table: "Vocabulary"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.entries.isEmpty && store.browsing?.total == 0)
                    }
                    Divider()
                    Button(String(localized: "Full notebook backup…", table: "Vocabulary"), action: backup)
                    Button(String(localized: "Restore notebook…", table: "Vocabulary"), action: chooseBackup)
                } label: { Image(systemName: "ellipsis.circle") }
                    .help(String(localized: "Export and backup", table: "Vocabulary"))
                    .disabled(!store.isLoaded && store.browsing?.isReady != true)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var lifecycleContent: some View {
        browserContent
        .environment(\.vocabularyTextSize, currentTextSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let addedSelection {
                HStack {
                    Text(store.readIndex.entriesByID[addedSelection.entryID]?.expression ?? "")
                        .font(.callout).lineLimit(1)
                    Spacer()
                    Button(String(localized: "Show in vocabulary", table: "Vocabulary")) {
                        revealAddedSelection(addedSelection)
                    }
                }.padding(10).background(.bar)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.canUndoSenseMerge {
                HStack {
                    Text(String(localized: "Senses merged. The destination’s content was kept.", table: "Vocabulary"))
                        .font(.callout)
                    Spacer()
                    Button(String(localized: "Undo merge", table: "Vocabulary")) {
                        Task { if let restored = await store.undoLastSenseMerge() { showSense(restored.senseID) } }
                    }
                    .accessibilityIdentifier("vocabularyUndoSenseMerge")
                }.padding(10).background(.bar)
            }
        }
        .onAppear { prepareBrowser(); if browserMode == "graph" { graph.reveal(graphSelection) } }
        .onDisappear { store.browsing?.deactivate() }
        .onChange(of: browseQuery) { _, _ in if usesPagedEntries { store.browse(browseQuery) } }
        .onChange(of: selectingSenses) { _, _ in prepareBrowser() }
        .onChange(of: store.browsing?.fence) { _, value in
            guard value != nil else { return }
            if let requestedID { store.browsing?.select(entryID: requestedID) } else if let activeSenseID {
                store.browsing?.select(senseID: activeSenseID)
            }
            store.browsing?.loadTagsIfNeeded()
        }
        .onChange(of: store.browsing?.detail) { _, entry in
            if let entry, requestedID == entry.id {
                selection = requestedSenseID ?? entry.defaultSense?.id
                expandedEntries.insert(entry.id); requestedID = nil; requestedSenseID = nil
            }
        }
        .onChange(of: selectedEntry, initial: true) { _, entry in
            learning?.select(entry, senseID: activeSenseID)
            // Selections that originate outside the sidebar (graph, "show in notebook") must
            // reveal their sense row. Insert-only: never collapse other entries, so rows above
            // the click target cannot shift. A headword click already expanded synchronously in
            // `activateHeadword`, making this a no-op for that path (no second, delayed jump).
            if let entry, entry.senses.count > 1, !expandedEntries.contains(entry.id) {
                expandedEntries.insert(entry.id)
            }
        }
        .onChange(of: activeSenseID) { _, id in
            if let addedSelection, addedSelection.senseID != id { self.addedSelection = nil }
            if let id, usesPagedEntries { store.browsing?.select(senseID: id) }
        }
        .onChange(of: selection) { _, _ in
            learning?.select(selectedEntry, senseID: activeSenseID)
            if browserMode == "graph", organization == "entry" { graph.reveal(graphSelection) }
        }
        .onChange(of: meaningDestination) { _, value in
            learning?.select(selectedEntry, senseID: activeSenseID)
            if let id = value?.nodeID {
                graph.revealMeaning(id, ancestors: categoryAncestors(forMeaning: id))
            } else if let id = value?.categoryID {
                let ancestors = VocabularyClassificationPolicy.ancestors(of: id, in: store.classification)
                graph.revealCategory(id, ancestors: ancestors)
            }
        }
        .onChange(of: organization) { _, value in
            prepareBrowser()
            graph.clearFocus(); graph.fitsInitialLayout = true
            if value == "meaning" {
                selectingSenses = false
                if meaningDestination == nil, let selection {
                    let nodes = Set(store.semantics.mappings.filter { $0.senseID == selection }.map(\.nodeID))
                    if nodes.count == 1, let id = nodes.first { meaningDestination = .node(id) }
                }
                if let id = meaningDestination?.nodeID {
                    graph.revealMeaning(id, ancestors: categoryAncestors(forMeaning: id))
                } else if let id = meaningDestination?.categoryID {
                    let ancestors = VocabularyClassificationPolicy.ancestors(of: id, in: store.classification)
                    graph.revealCategory(id, ancestors: ancestors)
                }
            } else {
                if let id = meaningDestination?.senseID { selection = id }
                graph.reveal(graphSelection)
            }
        }
        .onChange(of: store.semantics) { _, value in
            if let id = meaningDestination?.nodeID, !value.nodes.contains(where: { $0.id == id }) { meaningDestination = nil }
        }
        .onChange(of: store.classification) { _, value in
            if let id = meaningDestination?.categoryID,
               !value.categories.contains(where: { $0.id == id && !$0.isRetired }) {
                meaningDestination = nil
            }
        }
        .onChange(of: browserMode) { _, value in
            prepareBrowser()
            if value == "graph" {
                if organization == "meaning", let id = meaningDestination?.nodeID {
                    graph.revealMeaning(id, ancestors: categoryAncestors(forMeaning: id))
                } else if organization == "meaning", let id = meaningDestination?.categoryID {
                    let ancestors = VocabularyClassificationPolicy.ancestors(of: id, in: store.classification)
                    graph.revealCategory(id, ancestors: ancestors)
                } else if organization == "entry" { graph.reveal(graphSelection) }
            }
        }
        .onChange(of: store.entries) { _, entries in
            if !selectedTag.isEmpty, !entries.contains(where: { $0.senses.contains { $0.tags.contains(selectedTag) } }) {
                selectedTag = ""
            }
            if let requestedID, let entry = entries.first(where: { $0.id == requestedID }) {
                selection = requestedSenseID ?? entry.defaultSense?.id
                expandedEntries.insert(entry.id)
                self.requestedID = nil; requestedSenseID = nil
            } else if let selection, let entry = entries.first(where: { VocabularySensePolicy.index(selection, in: $0) != nil }),
                      let index = VocabularySensePolicy.index(selection, in: entry) {
                self.selection = entry.senses[index].id
            } else if selection != nil { selection = nil }
            if let id = meaningDestination?.senseID {
                if let entry = entries.first(where: { VocabularySensePolicy.index(id, in: $0) != nil }),
                   let index = VocabularySensePolicy.index(id, in: entry) {
                    meaningDestination = .sense(nodeID: meaningDestination?.nodeID, senseID: entry.senses[index].id)
                } else {
                    meaningDestination = meaningDestination?.nodeID.map(VocabularyMeaningDestination.node)
                }
            }
        }
        .onChange(of: query) { _, value in
            prepareBrowser()
            if search == nil, !value.isEmpty { expandedEntries.formUnion(visibleEntries.map(\.id)) }
            reconcileGraphSelection()
        }
        .onChange(of: selectedTag) { _, _ in reconcileGraphSelection() }
        .onChange(of: language) { _, _ in reconcileGraphSelection() }
    }

    private var sheetContent: some View {
        lifecycleContent
        .sheet(item: $exporting) { request in VocabularyExportSheet(store: store, request: request) }
        .sheet(isPresented: $creatingEntry) {
            VocabularyEntryCreationSheet(store: store, language: language ?? .english, onSaved: revealAddedEntries)
        }
        .sheet(isPresented: $creatingMeaning) {
            VocabularyMeaningEditor(store: store, categoryID: meaningDestination?.categoryID,
                preferredLanguages: meaningLanguages, onSaved: showMeaning)
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
        .sheet(item: $editing) { VocabularyEntryEditor(entry: $0, store: store, senseID: activeSenseID) }
    }

    var body: some View {
        sheetContent
        .alert(String(localized: "Replace notebook?", table: "Vocabulary"), isPresented: Binding(
            get: { restoreURL != nil }, set: { if !$0 { restoreURL = nil } })) {
                Button(String(localized: "Cancel"), role: .cancel) { restoreURL = nil }
                Button(String(localized: "Restore", table: "Vocabulary"), role: .destructive) {
                    if let url = restoreURL { Task { [scope = store.operationScope] in await store.restore(from: url, scope: scope) } }
                    restoreURL = nil
                }
            } message: { Text(String(localized: "Replace this notebook with the selected backup, including images and Anki associations.",
                table: "Vocabulary")) }
        .alert(String(localized: "Remove from vocabulary?", table: "Vocabulary"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(String(localized: "Cancel"), role: .cancel) { deleting = nil }
                Button(String(localized: "Delete"), role: .destructive) {
                    if let target = deleting { Task { [scope = store.operationScope] in
                        _ = await store.removeSense(entryID: target.entryID, senseID: target.senseID, scope: scope) } }
                    deleting = nil
                }
            }
        .alert(String(localized: "Vocabulary operation failed", table: "Vocabulary"), isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
    }

    private func reconcileGraphSelection() {
        // The asynchronous search controller owns nonempty queries in every browsing mode.
        // Re-running the legacy semantic projection here would block each search keystroke.
        if search != nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        if organization == "meaning" {
            if let id = meaningDestination?.nodeID, !meaningItems.contains(where: { $0.id == id }) {
                meaningDestination = nil; graph.clearFocus()
            }
            return
        }
        guard browserMode == "graph", let selection else { return }
        if !visibleEntries.contains(where: { VocabularySensePolicy.index(selection, in: $0) != nil }) {
            self.selection = nil
            graph.clearFocus()
        }
    }

    private var emptyNotebookContent: some View {
        VStack(spacing: 18) {
            LingroveBrandEmblem(logoSize: 58)

            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    LingroveWhaleGlyph(size: 12, tint: LingroveBrand.accent)
                    Text(ProductIdentity.appDisplayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LingroveBrand.accent)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(LingroveBrand.accent.opacity(0.11)))

                Text(String(localized: "No saved expressions", table: "Vocabulary"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(String(localized: "Save an expression while reading, add a sense yourself, or ask your agent to organize material.",
                    table: "Vocabulary"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            HStack(spacing: 10) {
                Button(String(localized: "Add entry", table: "Vocabulary")) { creatingEntry = true }
                    .buttonStyle(.borderedProminent)
                    .tint(LingroveBrand.accent)
                    .controlSize(.regular)
                    .accessibilityIdentifier("vocabularyEmptyAddEntry")

            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Keep the user's browsing context while showing the acknowledged saved sense. If its
    /// current filters hide the new row, an explicit reveal action can clear them; saving itself
    /// never discards the language, tag, query, density or organization the learner was using.
    private func revealAddedEntries(_ result: VocabularyEntryImportResult) {
        guard let target = result.selection else { return }
        expandedEntries.insert(target.entryID)
        showSense(target.senseID)
        addedSelection = target
    }

    private func revealAddedSelection(_ target: VocabularySelection) {
        query = ""; language = nil; selectedTag = ""; newestFirst = true
        browserMode = "list"; organization = "entry"
        expandedEntries.insert(target.entryID); selection = target.senseID; addedSelection = nil
    }

    private var graphBrowser: some View {
        let drawerWidth: CGFloat = 424
        let hasSelection = selectedSense != nil || selectedMeaning != nil || selectedCategory != nil
        return ZStack(alignment: .trailing) {
            VocabularyGraphView(
                entries: visibleEntries,
                contentRevision: store.contentRevision,
                language: language,
                tag: selectedTag,
                query: query,
                selection: graphSelection,
                presentation: graph,
                select: { next in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.92)) {
                        if let next {
                            showSense(next.senseID)
                        } else if organization == "meaning" { meaningDestination = nil } else { selection = nil }
                    }
                },
                trailingInset: hasSelection ? (drawerWidth + 16) : 0,
                meanings: organization == "meaning" ? store.semantics : nil,
                classification: organization == "meaning" ? store.classification : nil,
                showsUnexplored: showsUnexplored,
                meaningSelection: organization == "meaning" ? meaningDestination?.nodeID : nil,
                categorySelection: organization == "meaning" ? meaningDestination?.categoryID : nil,
                includeEmptyMeanings: language == nil && selectedTag.isEmpty,
                selectMeaning: { id in showMeaning(id) },
                selectCategory: { id in showCategory(id) }
            )
            .overlay(alignment: .topLeading) {
                graphFilterHUD
            }
            .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)

            if hasSelection {
                let drawerTitle: String = {
                    if let meaning = selectedMeaning {
                        return meaning.title(in: meaningLanguages)
                    }
                    if let category = selectedCategory {
                        return VocabularyClassificationPolicy.title(category, in: store.classification)
                    }
                    return selectedEntry?.expression ?? String(localized: "Core meaning", table: "Vocabulary")
                }()
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Label(
                            drawerTitle,
                            systemImage: selectedCategory?.axis.symbolName ?? "sparkles.rectangle.stack"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        Spacer()
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.94)) {
                                selection = nil
                                meaningDestination = nil
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
                    browserDetail
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

    private var isDetailedList: Bool {
        listDensity == "detailed"
    }

    private var currentTextSize: VocabularyTextSize {
        VocabularyTextSize(rawValue: textSizeRaw) ?? .standard
    }

    private func isEntrySelected(_ entry: VocabularyEntry) -> Bool {
        guard let selection else { return false }
        return VocabularySensePolicy.index(selection, in: entry) != nil
    }

    private func activateHeadword(_ entry: VocabularyEntry) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.96)) {
            if expandedEntries.contains(entry.id) {
                expandedEntries.remove(entry.id)
            } else {
                expandedEntries.insert(entry.id)
                if !isEntrySelected(entry) {
                    selection = entry.defaultSense?.id
                }
            }
        }
    }

    /// Row actions carry the clicked sense, which can differ from the open detail. Deletion
    /// hands that identity to the notebook's shared confirmation, just like the detail menu.
    @ViewBuilder private func senseContextMenu(_ target: VocabularySelection) -> some View {
        if let openReview = store.onRequestBuiltInReview {
            Button(String(localized: "Built-in review", table: "Vocabulary")) { openReview(target) }
        }
        if let entry = store.readIndex.entriesByID[target.entryID], entry.senses.count > 1 {
            Menu(String(localized: "Merge into…", table: "Vocabulary")) {
                ForEach(entry.presentationSenses.filter { $0.id != target.senseID }) { sense in
                    Button(sense.displayTitle) {
                        mergeSense(target, into: sense.id)
                    }
                }
            }
        } else if let entry = store.browsing?.entries.first(where: { $0.id == target.entryID }), entry.senses.count > 1 {
            Menu(String(localized: "Merge into…", table: "Vocabulary")) {
                ForEach(entry.senses.filter { $0.id != target.senseID }) { sense in
                    Button(summaryTitle(sense)) { mergeSense(target, into: sense.id) }
                }
            }
        }
        Button(String(localized: "Export this sense…", table: "Vocabulary")) { beginExport(single: target) }
        Button(role: .destructive) {
            deleting = target
        } label: {
            Label(String(localized: "Delete", table: "Vocabulary"), systemImage: "trash")
        }
    }

    /// Only the explicit row menu selects a merge destination. Capture scope and revision at
    /// the click so a delayed command cannot follow an account switch or overwrite newer edits.
    private func mergeSense(_ source: VocabularySelection, into target: UUID) {
        let ids = store.readIndex.entriesByID[source.entryID].map { $0.senses.map(\.id) }
            ?? store.browsing?.entries.first { $0.id == source.entryID }?.senses.map(\.id) ?? []
        guard source.senseID != target, ids.contains(source.senseID), ids.contains(target) else { return }
        let scope = store.operationScope, revision = scope?.revision ?? store.currentRevision
        Task {
            if await store.mergeSenses(entryID: source.entryID, source: source.senseID, target: target,
                scope: scope, expectedRevision: revision) { showSense(target) }
        }
    }

    private var listBrowser: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selection }, set: { next in
                // Collapsing a group removes its selected child row. Native List may clear
                // selection during that diff; keep the reading destination until another sense
                // is selected or the saved source is actually deleted.
                if let next, store.readIndex.selectionsBySenseID[next] != nil { selection = next }
            })) {
                ForEach(browser.listRows(entries: visibleEntries, expanded: expandedEntries)) { item in
                    VocabularyNotebookListRow(item: item, detailed: isDetailedList,
                        isSelected: item.sense.map { selection == $0.id } ?? isEntrySelected(item.entry),
                        isExpanded: expandedEntries.contains(item.entry.id), selecting: selectingSenses, query: query,
                        activate: { activateHeadword(item.entry) }, checkbox: senseCheckbox, menu: senseContextMenu)
                        .tag(item.sense?.id ?? item.entry.id)
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

    /// Summaries have their own presentation path. They never impersonate complete entries
    /// in the editing/export APIs; selecting a sense asks the read worker for its full entry.
    private var pagedListBrowser: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selection }, set: { id in
                if let id { selection = id }
            })) {
                ForEach(store.browsing?.entries ?? []) { entry in
                    if entry.senses.count == 1, let sense = entry.senses.first {
                        summarySense(entry, sense: sense, number: nil).tag(sense.id)
                            .onAppear { store.browsing?.loadMoreIfNeeded(after: entry.id) }
                    } else {
                        Button {
                            if expandedEntries.contains(entry.id) { expandedEntries.remove(entry.id) } else {
                                expandedEntries.insert(entry.id)
                                if !entry.senses.contains(where: { $0.id == selection }) { selection = entry.senses.first?.id }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: expandedEntries.contains(entry.id) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 13)
                                Text(entry.expression).font(currentTextSize.font(14.5, weight: .semibold, sidebar: true)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(entry.senses.count)").font(.caption).foregroundStyle(.secondary)
                                summaryLanguage(entry)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, isDetailedList ? 4 : 2.5)
                            .onAppear { store.browsing?.loadMoreIfNeeded(after: entry.id) }
                        if expandedEntries.contains(entry.id) {
                            ForEach(Array(entry.senses.enumerated()), id: \.element.id) { offset, sense in
                                summarySense(entry, sense: sense, number: offset + 1).tag(sense.id)
                            }
                        }
                    }
                }
                if store.browsing?.isLoading == true { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                if let error = store.browsing?.error {
                    VStack { Text(error).font(.callout); Button(String(localized: "Retry")) { store.browsing?.reload() } }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { sidebarFilterBar }
            .overlay {
                if store.browsing?.isReady == true, store.browsing?.total == 0 {
                    ContentUnavailableView(String(localized: "No matching expressions", table: "Vocabulary"), systemImage: "books.vertical")
                }
            }
            .navigationSplitViewColumnWidth(min: 245, ideal: 300, max: 420)
        } detail: { entryDetail }
    }

    private func summaryLanguage(_ entry: NotebookEntrySummary) -> some View {
        Text(entry.language?.compactLabel ?? String(localized: "Unspecified", table: "Learning"))
            .font(currentTextSize.font(10.5, weight: .semibold, sidebar: true)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func summarySense(_ entry: NotebookEntrySummary, sense: NotebookEntrySummary.Sense, number: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let number {
                    Text("\(number)").font(.caption).foregroundStyle(.tertiary)
                    Text(summaryTitle(sense))
                        .font(currentTextSize.font(13, sidebar: true)).lineLimit(1)
                } else {
                    Text(entry.expression).font(currentTextSize.font(14.5, weight: .semibold, sidebar: true)).lineLimit(1)
                    if !isDetailedList, selection == sense.id {
                        Text(summaryTitle(sense)).font(currentTextSize.font(12.5, sidebar: true)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4); summaryLanguage(entry)
                }
            }
            if number == nil, isDetailedList {
                Text(summaryTitle(sense))
                    .font(currentTextSize.font(13, sidebar: true)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.leading, number == nil ? 0 : 18).padding(.vertical, isDetailedList ? 4 : 2.5)
        .contextMenu { senseContextMenu(.init(entryID: entry.id, senseID: sense.id)) }
    }

    private func summaryTitle(_ sense: NotebookEntrySummary.Sense) -> String {
        if !sense.title.isEmpty { return sense.title }
        return sense.hasImage ? String(localized: "Image explanation", table: "Vocabulary")
            : String(localized: "Meaning pending", table: "Vocabulary")
    }

    private var meaningListBrowser: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarFilterBar
                VocabularyMeaningSidebar(
                    store: store,
                    items: meaningItems,
                    entries: scopedEntries,
                    unclassified: unclassified,
                    query: query,
                    isDetailed: isDetailedList,
                    showsUnexplored: $showsUnexplored,
                    destination: $meaningDestination
                )
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 315, max: 420)
        } detail: { browserDetail }
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

    /// Floating glass filter pill in the top-left corner of the graph canvas. Mirrors the
    /// sidebar's filter controls so switching between List and Graph never mutates or shifts
    /// the window toolbar.
    private var graphFilterHUD: some View {
        HStack(spacing: 6) {
            organizationSwitchPill
            filterMenus(compact: false)
            if organization == "meaning", !store.classification.categories.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.94)) {
                        showsUnexplored.toggle()
                    }
                } label: {
                    filterPillLabel(
                        title: String(localized: "Unexplored", table: "Vocabulary"),
                        symbol: showsUnexplored ? "eye.fill" : "eye.slash",
                        isActive: showsUnexplored
                    )
                }
                .buttonStyle(.plain)
                .help(String(localized: "Show unexplored categories", table: "Vocabulary"))
                .accessibilityIdentifier("vocabularyGraphToggleUnexplored")
            }
            collectionCount
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
            if organization == "meaning" {
                Button {
                    creatingMeaning = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "New meaning", table: "Vocabulary"))
                .disabled(!store.isLoaded)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        .padding(14)
    }

    /// Compact two-segment capsule toggle that switches the notebook between lexical entries
    /// ("By entry") and semantic groups ("By meaning") without adding a second top-toolbar picker.
    private var organizationSwitchPill: some View {
        HStack(spacing: 2) {
            organizationSegment(title: String(localized: "By entry", table: "Vocabulary"), value: "entry")
            organizationSegment(title: String(localized: "By meaning", table: "Vocabulary"), value: "meaning")
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vocabularyOrganization")
    }

    private func organizationSegment(title: String, value: String) -> some View {
        let isSelected = organization == value
        return Button {
            guard organization != value else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.94)) {
                organization = value
            }
        } label: {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? LingroveBrand.accent : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 7.5)
                .padding(.vertical, 2.5)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(LingroveBrand.accent.opacity(0.14))
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func filterMenus(compact: Bool) -> some View {
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
                title: language?.compactLabel ?? (compact ? nil : String(localized: "All languages", table: "Vocabulary")),
                symbol: "globe",
                isActive: language != nil
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "All languages", table: "Vocabulary"))

        if !allTags.isEmpty || usesPagedEntries {
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
                if !store.isLoaded, store.browsing?.tagsReady != true {
                    ProgressView().controlSize(.small)
                }
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
                    title: selectedTag.isEmpty
                        ? (compact ? nil : String(localized: "All tags", table: "Vocabulary"))
                        : "#\(selectedTag)",
                    symbol: "tag",
                    isActive: !selectedTag.isEmpty
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "All tags", table: "Vocabulary"))
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
    }

    /// Compact filter strip anchored above the sidebar list. Keeping organization, language, tag,
    /// and sort controls inside the sidebar eliminates main-toolbar clutter and visually ties
    /// filters to the list they govern.
    private var sidebarFilterBar: some View {
        HStack(spacing: 6) {
            organizationSwitchPill
            filterMenus(compact: true)

            Spacer(minLength: 4)

            collectionCount
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.94)) {
                    listDensity = isDetailedList ? "compact" : "detailed"
                }
            } label: {
                Image(systemName: isDetailedList ? "rectangle.grid.1x2" : "list.bullet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDetailedList ? LingroveBrand.accent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isDetailedList
                ? String(localized: "Detailed list", table: "Vocabulary")
                : String(localized: "Compact list", table: "Vocabulary"))

            if organization == "meaning" {
                Button {
                    creatingMeaning = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "New meaning", table: "Vocabulary"))
                .accessibilityIdentifier("vocabularyNewMeaning")
                .disabled(!store.isLoaded)
            } else {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private func filterPillLabel(title: String?, symbol: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            if let title, !title.isEmpty {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isActive ? LingroveBrand.accent : .secondary)
        .padding(.horizontal, title == nil ? 6.5 : 8)
        .padding(.vertical, 3.5)
        .background(
            Capsule(style: .continuous)
                .fill(isActive ? LingroveBrand.accent.opacity(0.12) : Color.primary.opacity(0.055))
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
                    .background(Capsule(style: .continuous).fill(LingroveBrand.accent))
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

                if let builtInReview {
                    Button {
                        let selections = batchSelection.sorted { $0.senseID.uuidString < $1.senseID.uuidString }
                        store.onRequestBuiltInReview?(nil)
                        builtInReview.requestBatch(selections)
                    } label: {
                        Label(BuiltInReviewCopy.text("batch.enroll"), systemImage: "rectangle.stack.badge.plus")
                            .font(.caption.weight(.medium)).frame(maxWidth: .infinity)
                    }.controlSize(.small).buttonStyle(.borderedProminent).disabled(batchSelection.isEmpty)
                        .accessibilityIdentifier("vocabulary.batch.lingrove")
                }
                if review != nil {
                    Button {
                        showingBatch = true
                    } label: {
                        Label(BuiltInReviewCopy.text("batch.anki"), systemImage: "arrow.up.forward.app")
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

    @ViewBuilder private var browserDetail: some View {
        if let node = selectedMeaning {
            VocabularyMeaningDetail(
                store: store,
                node: node,
                entries: scopedEntries,
                speech: speech,
                openSense: { showSense($0.senseID) },
                openMeaning: showMeaning,
                selectCategory: { id in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.94)) {
                        showCategory(id)
                    }
                }
            )
            .id(node.id)
        } else if let category = selectedCategory {
            VocabularyCategoryDetail(
                store: store,
                category: category,
                entries: scopedEntries,
                speech: speech,
                openCategory: { id in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.94)) {
                        showCategory(id)
                    }
                },
                openMeaning: showMeaning,
                openSense: { showSense($0.senseID) }
            )
            .id(category.id)
        } else if organization == "meaning", let senseID = meaningDestination?.senseID {
            entryDetail(breadcrumb: AnyView(meaningSenseBreadcrumbBar(activeSenseID: senseID)))
        } else if organization == "meaning", meaningDestination == .unclassified {
            VocabularyUnclassifiedDetail(store: store, entries: scopedEntries, unclassified: unclassified, speech: speech,
                openSense: { meaningDestination = .sense(nodeID: nil, senseID: $0.senseID) }, openMeaning: showMeaning)
        } else if organization == "meaning" {
            unselectedMeaningCanvas
        } else { entryDetail }
    }

    private var unselectedMeaningCanvas: some View {
        VStack(spacing: 16) {
            LingroveBrandEmblem(logoSize: 50)

            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    LingroveWhaleGlyph(size: 11, tint: LingroveBrand.accent)
                    Text(ProductIdentity.appDisplayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LingroveBrand.accent)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(LingroveBrand.accent.opacity(0.11)))

                Text(meaningItems.isEmpty
                    ? String(localized: "No meanings in this view", table: "Vocabulary")
                    : String(localized: "Browse by meaning", table: "Vocabulary"))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(String(localized:
                        "Select a semantic domain or meaning group to explore expressions by their role.",
                        table: "Vocabulary"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            HStack(spacing: 10) {
                Button(String(localized: "New meaning", table: "Vocabulary")) { creatingMeaning = true }
                    .buttonStyle(.borderedProminent)
                    .tint(LingroveBrand.accent)
                if !query.isEmpty || language != nil || !selectedTag.isEmpty {
                    Button(String(localized: "Clear filters", table: "Vocabulary")) {
                        query = ""; language = nil; selectedTag = ""
                    }
                }
                if !unclassified.isEmpty {
                    Button(String(localized: "Other expressions", table: "Vocabulary") + " (\(unclassified.count))") {
                        meaningDestination = .unclassified
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Contextual breadcrumb and sibling expression switcher bar shown when drilling into a single
    /// sense from "By meaning" mode. Keeps the parent meaning context visible and allows one-click
    /// hopping between sibling expressions without backing out to the comparison matrix.
    private func meaningSenseBreadcrumbBar(activeSenseID: UUID) -> some View {
        let parentNode = meaningDestination?.nodeID.flatMap { id in
            store.semantics.nodes.first { $0.id == id }
        }
        let parentTitle = parentNode?.title(in: meaningLanguages)
            ?? String(localized: "Other expressions", table: "Vocabulary")
        let siblingSelections: [VocabularySelection] = {
            guard let nodeID = parentNode?.id else { return [] }
            let senseIDs = Set(store.semantics.mappings.filter { $0.nodeID == nodeID }.map(\.senseID))
            return scopedEntries.flatMap { entry in
                entry.senses
                    .filter { senseIDs.contains($0.id) }
                    .map { VocabularySelection(entryID: entry.id, senseID: $0.id) }
            }
        }()

        return HStack(spacing: 10) {
            Button {
                meaningDestination = parentNode.map { .node($0.id) } ?? .unclassified
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(currentTextSize.font(10.5, weight: .bold))
                    if let parentNode {
                        Image(systemName: parentNode.kind == .function ? "bubble.left.and.text.bubble.right" : "circle.hexagongrid")
                            .font(currentTextSize.font(10.5, weight: .semibold))
                    }
                    Text(parentTitle)
                        .font(currentTextSize.font(12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(LingroveBrand.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(LingroveBrand.accent.opacity(0.11))
                )
            }
            .buttonStyle(.plain)

            if siblingSelections.count > 1 {
                Image(systemName: "chevron.right")
                    .font(currentTextSize.font(9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(siblingSelections, id: \.self) { selection in
                            if let entry = scopedEntries.first(where: { $0.id == selection.entryID }) {
                                let isCurrent = selection.senseID == activeSenseID
                                Button {
                                    meaningDestination = .sense(nodeID: parentNode?.id, senseID: selection.senseID)
                                } label: {
                                    Text(entry.expression)
                                        .font(currentTextSize.font(12, weight: isCurrent ? .semibold : .medium))
                                        .foregroundStyle(isCurrent ? .primary : .secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3.5)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(isCurrent ? Color.primary.opacity(0.09) : Color.primary.opacity(0.035))
                                        )
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(isCurrent ? Color.primary.opacity(0.18) : Color.clear, lineWidth: 0.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var entryDetail: some View {
        entryDetail(breadcrumb: nil)
    }

    @ViewBuilder private func entryDetail(breadcrumb: AnyView?) -> some View {
        if let entry = selectedEntry, let sense = selectedSense {
            VocabularyEntryDetail(entry: entry, sense: sense, speech: speech, store: store, learning: learning,
                review: review, builtInReview: builtInReview,
                edit: { editing = entry }, delete: { deleting = .init(entryID: entry.id, senseID: sense.id) },
                selectSense: { id in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1.0)) {
                        showSense(id)
                    }
                }, filterByTag: { tag in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        selectedTag = selectedTag == tag ? "" : tag
                    }
                }, openMeaning: showMeaning, breadcrumb: breadcrumb)
                .id(sense.id)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: sense.id)
        } else if usesPagedEntries, activeSenseID != nil,
                  store.browsing?.isLoadingDetail == true || store.browsing?.isLoading == true {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unselectedEntryCanvas
        }
    }

    private var unselectedEntryCanvas: some View {
        VStack(spacing: 16) {
            LingroveBrandEmblem(logoSize: 52)

            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    LingroveWhaleGlyph(size: 11, tint: LingroveBrand.accent)
                    Text(ProductIdentity.appDisplayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LingroveBrand.accent)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(LingroveBrand.accent.opacity(0.11)))

                Text(String(localized: "Vocabulary", table: "Vocabulary"))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(String(localized: "\(storedEntryCount) entries stored"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 10) {
                Button(String(localized: "Add entry", table: "Vocabulary")) { creatingEntry = true }
                    .buttonStyle(.borderedProminent)
                    .tint(LingroveBrand.accent)

            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedEntry: VocabularyEntry? {
        guard let selection = activeSenseID else { return nil }
        if usesPagedEntries, let detail = store.browsing?.detail, VocabularySensePolicy.index(selection, in: detail) != nil {
            return detail
        }
        return store.readIndex.entry(forSense: selection)
    }
    private var selectedSense: VocabularySense? {
        guard let selection = activeSenseID, let entry = selectedEntry,
              let index = VocabularySensePolicy.index(selection, in: entry) else { return nil }
        return entry.senses[index]
    }

    private var storedEntryCount: Int { store.browsing?.isReady == true ? store.browsing?.total ?? 0 : store.entries.count }

    private func selections(in entries: [VocabularyEntry]) -> [VocabularySelection] {
        entries.flatMap { entry in entry.senses.map { .init(entryID: entry.id, senseID: $0.id) } }
    }

    private func beginExport(scope: VocabularyExportScope? = nil, single: VocabularySelection? = nil) {
        guard store.isLoaded else {
            let identity = store.scopeIdentity
            Task {
                await store.load()
                guard identity == store.scopeIdentity, store.isLoaded else { return }
                beginExport(scope: scope, single: single)
            }
            return
        }
        let all = selections(in: store.entries.sorted { newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt })
        let selected = single.map { [$0] } ?? all.filter { batchSelection.contains($0) }
        let initial = single != nil ? VocabularyExportScope.selected : scope ?? (!selected.isEmpty ? .selected :
            query.isEmpty && language == nil && selectedTag.isEmpty ? .all : .filtered)
        let filtered: [VocabularySelection]
        if let search, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard search.hasCurrentResults(for: query) else { return }
            filtered = search.results.selections
        } else {
            filtered = organization == "meaning" ? Array(Set(meaningItems.flatMap(\.selections) + unclassified))
                : selections(in: visibleEntries)
        }
        exporting = .init(all: all, filtered: filtered, selected: selected, initialScope: initial)
    }

    private func backup() {
        let scope = store.operationScope
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lingrove") ?? .data]
        panel.nameFieldStringValue = "Lingrove-vocabulary.lingrove"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await store.backup(to: url, scope: scope) }
        }
    }

    private func chooseBackup() {
        let identity = store.scopeIdentity
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lingrove") ?? .data]
        panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK, identity == store.scopeIdentity { restoreURL = panel.url } }
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
    var builtInReview: BuiltInReviewSession?
    let edit: () -> Void
    let delete: () -> Void
    var selectSense: ((UUID) -> Void)?
    var filterByTag: ((String) -> Void)?
    var openMeaning: ((UUID) -> Void)?
    var breadcrumb: AnyView?
    @Environment(\.vocabularyTextSize) private var textSize

    @State private var definitionLanguageID = ""
    @State private var preparingMeanings = false

    private var hasSemanticContent: Bool {
        VocabularySenseSemanticSection.hasContent(in: store.semantics, for: sense.id)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let breadcrumb {
                    breadcrumb
                        .padding(.bottom, -8)
                }
                heroHeader
                if entry.senses.count > 1 {
                    senseSwitcherBar
                }
                coreMeaningSection
                senseExplanationAndNotesSection
                if !sense.examples.isEmpty {
                    examplesSection
                }
                if hasSemanticContent {
                    VocabularySenseSemanticSection(store: store, selection: .init(entryID: entry.id, senseID: sense.id),
                        openMeaning: openMeaning)
                } else if !store.isLoaded, store.browsing?.readDetail?.mappedSenseIDs.contains(sense.id) == true {
                    Button {
                        preparingMeanings = true
                        Task { await store.load(); preparingMeanings = false }
                    } label: {
                        HStack {
                            if preparingMeanings { ProgressView().controlSize(.small) }
                            Label(String(localized: "By meaning", table: "Vocabulary"), systemImage: "circle.hexagongrid")
                        }
                    }.buttonStyle(.bordered).disabled(preparingMeanings)
                }
                if review != nil || builtInReview != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "Review", table: "Vocabulary")).font(.headline)
                        if let builtInReview {
                            VocabularyBuiltInReviewSection(entry: entry, sense: sense, store: store, session: builtInReview)
                        }
                        if let review { VocabularyReviewSection(entry: entry, sense: sense, controller: review, compact: true) }
                    }
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
        .onDisappear { speech.stop(ownerID: sense.id) }
    }

    /// Editorial headword block with inline audio playback, tactile copy confirmation, and
    /// metadata pills (language, lemma, and clickable tags).
    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.expression)
                    .font(textSize.font(28, weight: .bold))
                    .tracking(-0.3)
                    .textSelection(.enabled)
                speaker(text: entry.expression, item: "expression", language: entry.language)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Spacer(minLength: 6)
                HStack(alignment: .center, spacing: 6) {
                    VocabularyCopyActionButton(
                        title: String(localized: "Copy expression", table: "Vocabulary"),
                        text: entry.expression
                    )
                    Menu {
                        Button(action: edit) {
                            Label(String(localized: "Edit", table: "Vocabulary"), systemImage: "pencil")
                        }
                        if builtInReview == nil, let openReview = store.onRequestBuiltInReview {
                            Button {
                                openReview(.init(entryID: entry.id, senseID: sense.id))
                            } label: {
                                Label(String(localized: "Built-in review", table: "Vocabulary"), systemImage: "rectangle.stack.badge.play")
                            }
                            .accessibilityIdentifier("vocabularySenseBuiltInReview")
                        }
                        Divider()
                        Button(role: .destructive, action: delete) {
                            Label(String(localized: "Delete", table: "Vocabulary"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(String(localized: "Edit", table: "Vocabulary"))
                }
                .fixedSize(horizontal: true, vertical: false)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }

            HStack(spacing: 6) {
                metadataBadge((entry.language?.label ?? String(localized: "Unspecified", table: "Learning")), tint: LingroveBrand.accent)
                if entry.dictionaryForm != entry.expression {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(textSize.font(9.5, weight: .semibold))
                        Text(entry.dictionaryForm)
                            .font(textSize.font(12, weight: .medium))
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
                            .font(textSize.font(12, weight: .medium))
                            .foregroundStyle(LingroveBrand.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(LingroveBrand.accent.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func metadataBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(textSize.font(12, weight: .semibold))
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
                ForEach(Array(entry.presentationSenses.enumerated()), id: \.element.id) { index, item in
                    let isSelected = item.id == sense.id
                    Button {
                        selectSense?(item.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(index + 1)")
                                .font(textSize.font(10.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? .white : .secondary)
                                .frame(width: 17, height: 17)
                                .background(
                                    Circle().fill(isSelected ? LingroveBrand.accent : Color.primary.opacity(0.08))
                                )
                            Text(item.displayTitle)
                                .font(textSize.font(12.5, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 5)
                        .padding(.trailing, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? LingroveBrand.accent.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(isSelected ? LingroveBrand.accent.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }

            }
        }
    }

    /// The saved sense supplies its current summary. Capture receipts and prior model
    /// wordings are provenance, never additional definitions in the reading surface.
    @ViewBuilder
    private var coreMeaningSection: some View {
        let variants = VocabularyContentPolicy.languageVariants(text: sense.meaning,
            language: sense.meaningLanguage, variants: sense.standaloneMeanings)
        if let meaning = variants.first(where: { $0.id == definitionLanguageID }) ?? variants.first {
            VStack(alignment: .leading, spacing: 10) {
                if variants.count > 1 {
                    Picker(String(localized: "Meaning language", table: "Vocabulary"),
                        selection: Binding(get: { meaning.id }, set: { definitionLanguageID = $0 })) {
                        ForEach(variants) { value in
                            Text(value.language?.label ?? String(localized: "Unspecified", table: "Learning")).tag(value.id)
                        }
                    }.pickerStyle(.menu).fixedSize()
                }
                Text(meaning.text)
                    .font(textSize.font(19, weight: .semibold))
                    .lineSpacing(3)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The current explanation and usage patterns share the existing callout. Personal notes
    /// retain their ownership; missing optional content creates no editing task in the reader.
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
                                .font(textSize.font(12, weight: .semibold))
                                .foregroundStyle(.secondary)
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
                            .font(textSize.font(12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(sense.note)
                            .font(textSize.font(14.5))
                            .lineSpacing(3.5)
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
        }
    }

    private var examplesSection: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(sense.presentationExamples) { example in
                VocabularyExampleCard(
                    entry: entry,
                    sense: sense,
                    example: example,
                    speech: speech
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

    private func speaker(text: String, item: String, language: LearningLanguage?) -> some View {
        LearningSpeechButton(speech: speech, request: SpeechRequest(target: SpeechTarget(ownerID: sense.id, itemID: "vocabulary." + item),
            text: text, language: language), playLabel: String(localized: "Read aloud", table: "Vocabulary"),
            stopLabel: String(localized: "Stop reading", table: "Vocabulary"))
    }
}

/// Elevated card for one encountered usage example. Highlights the target expression with a soft
/// accent marker tint and pairs source and translation with the existing inline TTS buttons and
/// source provenance. Organization commands are owned by the agent, outside reading.
private struct VocabularyExampleCard: View {
    let entry: VocabularyEntry
    let sense: VocabularySense
    let example: VocabularyExample
    let speech: LearningSpeechController
    @Environment(\.vocabularyTextSize) private var textSize
    @State private var hovering = false
    @State private var translationLanguageID = ""

    private var contextTitle: String {
        switch example.completeness {
        case .sentence: String(localized: "Example sentence", table: "Vocabulary")
        case .fragment: String(localized: "Context fragment", table: "Vocabulary")
        case .unknown: String(localized: "Context")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: example.completeness == .sentence ? "quote.opening" : "text.quote")
                    .font(textSize.font(10.5, weight: .bold))
                    .foregroundStyle(LingroveBrand.accent)
                Text(contextTitle)
                    .font(textSize.font(12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()

            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Text(highlighted(example))
                        .font(textSize.font(16.5))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    speaker(text: example.text, item: example.id.uuidString, language: entry.language)
                }
                let variants = VocabularyContentPolicy.languageVariants(text: example.translation,
                    language: example.translationLanguage, variants: example.translationVariants)
                if let translation = variants.first(where: { $0.id == translationLanguageID }) ?? variants.first {
                    if variants.count > 1 {
                        Picker(String(localized: "Translation", table: "Vocabulary"),
                            selection: Binding(get: { translation.id }, set: { translationLanguageID = $0 })) {
                            ForEach(variants) { value in
                                Text(value.language?.label ?? String(localized: "Unspecified", table: "Learning")).tag(value.id)
                            }
                        }.pickerStyle(.menu).fixedSize()
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text(translation.text)
                            .font(textSize.font(14.5))
                            .lineSpacing(3)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        speaker(text: translation.text, item: example.id.uuidString + ".translation",
                            language: translation.language)
                    }
                }
            }

            if let app = example.appBundleIdentifier,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                HStack(spacing: 5) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                    Text(FileManager.default.displayName(atPath: url.path))
                        .font(textSize.font(11.5, weight: .medium))
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

    private func speaker(text: String, item: String, language: LearningLanguage?) -> some View {
        LearningSpeechButton(speech: speech, request: SpeechRequest(target: SpeechTarget(ownerID: sense.id, itemID: "vocabulary." + item),
            text: text, language: language), playLabel: String(localized: "Read aloud", table: "Vocabulary"),
            stopLabel: String(localized: "Stop reading", table: "Vocabulary"))
    }

    private func highlighted(_ example: VocabularyExample) -> AttributedString {
        var result = AttributedString(example.text)
        for value in example.ranges {
            guard VocabularyPolicy.valid(value.nsRange, in: example.text), let range = Range(value.nsRange, in: example.text),
                  let converted = Range(range, in: result) else { continue }
            result[converted].font = textSize.font(16.5, weight: .semibold)
            result[converted].foregroundColor = LingroveBrand.accent
            result[converted].backgroundColor = LingroveBrand.accent.opacity(0.11)
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

/// The flattened list keeps one cell per identity. It owns no service or collection; the
/// notebook supplies actions and saved values, while the native List owns selection/scrolling.
private struct VocabularyNotebookListRow<Checkbox: View, Menu: View>: View {
    let item: VocabularyBrowserRow
    let detailed: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let selecting: Bool
    let query: String
    let activate: () -> Void
    @ViewBuilder let checkbox: (VocabularyEntry, VocabularySense) -> Checkbox
    @ViewBuilder let menu: (VocabularySelection) -> Menu

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let sense = item.sense {
                if selecting { checkbox(item.entry, sense).padding(.top, 2) }
                if item.entry.senses.count == 1 {
                    VocabularySingleEntryRow(entry: item.entry, sense: sense, isDetailed: detailed,
                        isSelected: isSelected, query: query)
                } else {
                    VocabularySidebarSenseRow(sense: sense, index: item.senseNumber, query: query)
                        .padding(.leading, 18)
                }
            } else {
                Button(action: activate) {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 13)
                        VocabularyMultiSenseHeaderRow(entry: item.entry, isDetailed: detailed,
                            isExpanded: isExpanded, isSelected: isSelected)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityValue(isExpanded ? String(localized: "Expanded", table: "Learning")
                    : String(localized: "Collapsed", table: "Learning"))
            }
        }
        .padding(.vertical, detailed ? 4 : 2.5)
        .contextMenu {
            if let sense = item.sense { menu(.init(entryID: item.entry.id, senseID: sense.id)) }
        }
    }
}

/// Flat, scannable sidebar row for the single-sense entry case.
/// In Compact mode (`isDetailed == false`), it maintains a strictly constant single-line height
/// so clicking between entries never causes `NSTableView` row-height reflows or vertical jitter;
/// selecting the row reveals an inline meaning preview on the same baseline. In Detailed mode
/// (`isDetailed == true`), it renders a stable two-line headword + meaning layout.
private struct VocabularySingleEntryRow: View {
    let entry: VocabularyEntry
    let sense: VocabularySense
    let isDetailed: Bool
    let isSelected: Bool
    let query: String
    @Environment(\.vocabularyTextSize) private var textSize

    private var matchedExampleSnippet: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !entry.expression.localizedStandardContains(trimmed),
              !sense.displayTitle.localizedStandardContains(trimmed) else { return nil }
        return sense.presentationExamples.first {
            $0.text.localizedStandardContains(trimmed) || $0.translation.localizedStandardContains(trimmed)
        }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.expression)
                    .font(textSize.font(14.5, weight: .semibold, sidebar: true))
                    .lineLimit(1)
                if !isDetailed && isSelected && !sense.displayTitle.isEmpty {
                    Text(sense.displayTitle)
                        .font(textSize.font(12.5, sidebar: true))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: 4)
                if !(sense.reviewCards ?? []).isEmpty {
                    Image(systemName: "rectangle.stack.fill")
                        .font(textSize.font(9.5, sidebar: true))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Text((entry.language?.compactLabel ?? String(localized: "Unspecified", table: "Learning")))
                    .font(textSize.font(10.5, weight: .semibold, sidebar: true))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            if isDetailed {
                Text(sense.displayTitle)
                    .font(textSize.font(13, sidebar: true))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let snippet = matchedExampleSnippet {
                Text(snippet)
                    .font(textSize.font(12, sidebar: true))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }
}

/// Full-row clickable header for multi-sense entries in the sidebar. Clicking anywhere on this
/// header selects and expands the entry in-place without forcing the user to aim at the tiny
/// disclosure triangle, while keeping a constant header height so expanding never causes a double
/// vertical jump.
private struct VocabularyMultiSenseHeaderRow: View {
    let entry: VocabularyEntry
    let isDetailed: Bool
    let isExpanded: Bool
    let isSelected: Bool
    @Environment(\.vocabularyTextSize) private var textSize

    private var combinedSummary: String {
        entry.senses.map(\.displayTitle).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.expression)
                    .font(textSize.font(14.5, weight: .semibold, sidebar: true))
                    .foregroundStyle(isSelected ? LingroveBrand.accent : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text((entry.language?.compactLabel ?? String(localized: "Unspecified", table: "Learning")))
                    .font(textSize.font(10.5, weight: .semibold, sidebar: true))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                Text("\(entry.senses.count)")
                    .font(textSize.font(10.5, weight: .semibold, sidebar: true))
                    .monospacedDigit()
                    .foregroundStyle(LingroveBrand.accent)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(LingroveBrand.accent.opacity(0.12)))
            }
            if isDetailed && !combinedSummary.isEmpty {
                Text(combinedSummary)
                    .font(textSize.font(13, sidebar: true))
                    .foregroundStyle(isExpanded ? .tertiary : .secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact child row for an expanded multi-sense entry in the sidebar. Keeps each sense to a
/// clean numbered meaning line plus usage count so expanding a word never floods the list with
/// multi-line example paragraphs.
private struct VocabularySidebarSenseRow: View {
    let sense: VocabularySense
    let index: Int
    let query: String
    @Environment(\.vocabularyTextSize) private var textSize

    private var matchedExampleSnippet: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sense.displayTitle.localizedStandardContains(trimmed) else { return nil }
        return sense.presentationExamples.first {
            $0.text.localizedStandardContains(trimmed) || $0.translation.localizedStandardContains(trimmed)
        }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index)")
                    .font(textSize.font(10.5, weight: .bold, sidebar: true))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
                Text(sense.displayTitle)
                    .font(textSize.font(13, weight: .medium, sidebar: true))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !sense.examples.isEmpty {
                    Text("\(sense.examples.count)")
                        .font(textSize.font(11, sidebar: true))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            if let snippet = matchedExampleSnippet {
                Text(snippet)
                    .font(textSize.font(12, sidebar: true))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The notebook list and its Home walkthrough share the exact sense label. Selection remains
/// the host's responsibility; this value-only component never edits or reclassifies a usage.
struct VocabularySenseSummary: View {
    let sense: VocabularySense
    @Environment(\.vocabularyTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sense.displayTitle)
                    .font(textSize.font(14, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(String(localized: "\(sense.examples.count) examples", table: "Vocabulary"))
                    .font(textSize.font(11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            if let example = sense.defaultExample {
                Text(example.text)
                    .font(textSize.font(12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !sense.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(sense.tags.prefix(3), id: \.self) { tag in
                        Text("#" + tag)
                            .font(textSize.font(11, weight: .medium))
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
