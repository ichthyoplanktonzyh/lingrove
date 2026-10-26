import Combine
import SwiftUI

/// These are product journeys, not providers. Home owns the selected journey and its local
/// timeline; guide/onboarding navigation never depends on these transient values.
enum HomeLearningScene: String, CaseIterable, Identifiable {
    case writing, expression, reading, lookup, speech, vocabulary, anki
    var id: String { rawValue }
    var title: String {
        switch self {
        case .expression: String(localized: "Expression assistance", table: "Learning")
        case .writing: String(localized: "Writing")
        case .reading: String(localized: "Reading", table: "Learning")
        case .lookup: String(localized: "Dictionary", table: "Learning")
        case .speech: String(localized: "Read Aloud", table: "Learning")
        case .vocabulary: String(localized: "Vocabulary", table: "Vocabulary")
        case .anki: "Anki"
        }
    }
    var steps: [HomeLearningDemoAction] {
        switch self {
        case .expression: [.expressionTrigger, .expressionDescribe, .expressionChoose, .expressionInsert]
        case .writing: [.preview, .expand, .explain, .favorite, .favoriteMenu, .collapse, .speak, .replace, .dismiss]
        case .reading: [.select, .preview, .pointer, .preview, .capture, .preview, .expand]
        case .lookup: [.lookup, .explain, .dictionary, .sources, .favorite, .favoriteMenu]
        case .speech: [.preview, .speak, .expand]
        case .vocabulary: [.list, .sense, .graph, .headword, .sense]
        case .anki: [.layout, .layoutBack, .addAnki, .reviewAnki]
        }
    }
}

/// One meaningful step highlights one real control and explains its purpose outside the card.
/// Copy and action identity stay together so automatic playback and manual stepping cannot drift.
enum HomeLearningDemoAction: String {
    case expressionTrigger, expressionDescribe, expressionChoose, expressionInsert
    case preview, expand, collapse, explain, favorite, favoriteMenu, speak, replace, dismiss
    case lookup, dictionary, sources, select, pointer, capture, list, graph, headword, sense, layout, layoutBack, addAnki, reviewAnki
    var emphasis: LearningCardAction? {
        switch self {
        case .expand, .collapse: .expand
        case .explain: .explanation
        case .favorite, .favoriteMenu: .favorite
        case .speak: .speech
        case .replace: .replace
        case .dismiss: .dismiss
        case .sources: .dictionarySources
        default: nil
        }
    }
    var title: String {
        switch self {
        case .expressionTrigger: String(localized: "Trigger symbols", table: "Learning")
        case .expressionDescribe: String(localized: "Describe what you mean", table: "Learning")
        case .expressionChoose: String(localized: "Select", table: "Learning")
        case .expressionInsert: String(localized: "Insert", table: "Learning")
        case .preview: String(localized: "Translation", table: "Learning")
        case .expand: String(localized: "Expand", table: "Learning")
        case .collapse: String(localized: "Collapse", table: "Learning")
        case .explain: String(localized: "AI explanation", table: "Learning")
        case .favorite: String(localized: "Save to vocabulary", table: "Vocabulary")
        case .favoriteMenu: String(localized: "Saved · Show actions", table: "Vocabulary")
        case .speak: String(localized: "Read Aloud", table: "Learning")
        case .replace: String(localized: "Replace", table: "Learning")
        case .dismiss: String(localized: "Dismiss")
        case .lookup: String(localized: "Contextual meaning", table: "Learning")
        case .dictionary: String(localized: "Dictionary", table: "Learning")
        case .sources: String(localized: "Dictionary sources", table: "Learning")
        case .select: LearningReadingSource.selection.title
        case .pointer: LearningReadingSource.pointer.title
        case .capture: LearningReadingSource.screenshot.title
        case .list: String(localized: "List", table: "Vocabulary")
        case .graph: String(localized: "Graph", table: "Vocabulary")
        case .headword: String(localized: "Headwords", table: "Vocabulary")
        case .sense: String(localized: "Senses", table: "Vocabulary")
        case .layout: String(localized: "Front", table: "Vocabulary")
        case .layoutBack: String(localized: "Back", table: "Vocabulary")
        case .addAnki: String(localized: "Add to Anki", table: "Vocabulary")
        case .reviewAnki: String(localized: "Review in Anki", table: "Vocabulary")
        }
    }
    var explanation: String {
        switch self {
        case .expressionTrigger: String(localized: "Type your trigger symbols or use the expression shortcut at the caret.",
            table: "Learning")
        case .expressionDescribe: String(localized: "Describe the expression or term in the temporary input, then pause.",
            table: "Learning")
        case .expressionChoose: String(localized: "Use arrow keys to compare candidates and their hints.", table: "Learning")
        case .expressionInsert: String(localized: "Press Enter or Tab to insert the selected candidate; Escape cancels.", table: "Learning")
        case .preview: String(localized: "Pause after typing to see a sentence preview.", table: "Learning")
        case .expand, .collapse: String(localized: "Expand the card to compare the original and translation.", table: "Learning")
        case .explain: String(localized: "Use AI to explain the current sentence or expression.", table: "Learning")
        case .favorite: String(localized: "Save the current sentence or expression with its context.", table: "Learning")
        case .favoriteMenu: String(localized: "Use the fish-tail menu to view or remove this saved usage.", table: "Learning")
        case .speak: String(localized: "Click the speaker to start reading; click it again to stop.", table: "Learning")
        case .replace: String(localized: "Replace only the preview's saved source range.", table: "Learning")
        case .dismiss: String(localized: "Close the preview without changing the text.", table: "Learning")
        case .lookup: String(localized: "Double-click a word or expression to open its contextual meaning.", table: "Learning")
        case .dictionary: String(localized: "Switch from contextual meaning to dictionary definitions.", table: "Learning")
        case .sources: String(localized: "Choose another dictionary source from the source menu.", table: "Learning")
        case .select: String(localized: "Select text outside an editor, then use the translation icon or shortcut.", table: "Learning")
        case .pointer: String(localized: "Point at a word and use the pointer translation shortcut.", table: "Learning")
        case .capture: String(localized: "Choose a screen region to extract its text and translate it.", table: "Learning")
        case .list: String(localized: "Expand a headword and select one of its senses.", table: "Learning")
        case .graph: String(localized: "Switch to Graph to browse the same saved expressions.", table: "Learning")
        case .headword: String(localized: "Click a headword to reveal its senses; drag nodes to move the graph.", table: "Learning")
        case .sense: String(localized: "Click a sense to view its meaning and examples.", table: "Learning")
        case .layout, .layoutBack: String(localized: "Choose and arrange content separately for the front and back.", table: "Learning")
        case .addAnki: String(localized: "Add the configured card to Anki.", table: "Learning")
        case .reviewAnki: String(localized: "Review the saved card in Anki.", table: "Learning")
        }
    }
}

/// One mounted Home walkthrough owns these lightweight sessions and one existing in-memory
/// notebook. Real card views perform their normal actions against the normal session/store APIs.
/// Only the demo's scheduler chooses steps; it never observes a global keyboard or AX focus.
@MainActor
final class HomeLearningDemoModel: ObservableObject {
    @Published private(set) var scene = HomeLearningScene.writing
    @Published private(set) var step = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var editorText = "谢谢你的帮助。" + HomeLearningDemoFixtures.source + "我们下周再确认。"
    @Published var expanded = false
    @Published var cardVisible = true
    @Published var lookupVisible = false
    @Published var favoriteMenuPresented = false
    @Published var dictionaryMenuPresented = false
    @Published var bookMode = "list"
    @Published var bookSelection: VocabularySelection?
    @Published var expandedHeadwords: Set<UUID> = []
    @Published var presentsNotebook = false
    @Published var readingSource = LearningReadingSource.selection
    @Published var ankiSession: AnkiReviewSession?
    @Published var ankiDestinationShown = false
    @Published var previewBack = false
    @Published var reviewFailure: String?
    @Published private(set) var ready = false
    let store = VocabularyStore(archive: VocabularyArchive(url: nil))
    let explainer = HomeDemoExplainer()
    let explanation: LearningExplanationSession
    let dictionary: LearningDictionarySession
    let speech: LearningSpeechController
    let graph: VocabularyGraphPresentation
    let notebook: VocabularyNotebookSession
    let review: AnkiReviewController
    let preferences: UserDefaults
    let readingSettings: LanguageLearningSettings
    private var preparation: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var revision = UUID()
    private var hoveredPlayback = false
    private var manuallyControlled = false
    private let cardID = UUID()

    init(preferences: UserDefaults? = nil, speechProvider: (any SpeechProviding)? = nil) {
        let preferences = preferences ?? UserDefaults(suiteName: "io.ichthyoplanktonzyh.lingrove.home-demo") ?? .standard
        self.preferences = preferences
        readingSettings = LanguageLearningSettings(defaults: preferences)
        let speechSettings = LearningSpeechSettings(defaults: preferences)
        speechSettings.selectProvider(.system)
        speech = LearningSpeechController(settings: speechSettings,
            provider: speechProvider ?? SystemSpeechProvider(), generator: HomeDemoAudioGenerator())
        graph = VocabularyGraphPresentation(defaults: preferences)
        explanation = LearningExplanationSession(service: explainer)
        dictionary = LearningDictionarySession(provider: HomeDemoDictionary(), explanationService: explainer)
        notebook = VocabularyNotebookSession(service: explainer, provider: HomeDemoDictionary())
        review = AnkiReviewController(settings: AnkiReviewSettings(defaults: preferences,
            credentials: AnkiCredentialStore(service: nil)), store: store, client: HomeDemoAnki(), activateAnki: {})
        explanation.setTarget(LearningExplanationPolicy.input(VocabularyCaptureFactory.preview(presentation)
            ?? HomeLearningDemoFixtures.capture))
        store.openSelection = { [weak self] selection in
            guard let self else { return }
            self.select(.vocabulary)
            self.selectSense(selection)
        }
    }

    var action: HomeLearningDemoAction { scene.steps[step] }
    var presentation: LearningSentencePresentation {
        let reading = scene == .reading
        let source: String
        let translation: String
        if reading {
            switch readingSource {
            case .selection: source = HomeLearningDemoFixtures.translation; translation = HomeLearningDemoFixtures.source
            case .pointer: source = "posted"; translation = "获知最新情况"
            case .screenshot: source = HomeLearningDemoFixtures.ocrSource; translation = HomeLearningDemoFixtures.ocrTranslation
            }
        } else { source = HomeLearningDemoFixtures.source; translation = HomeLearningDemoFixtures.translation }
        var value = LearningSentencePresentation(id: HomeLearningDemoFixtures.documentID, source: source, translation: translation,
            sourceLanguage: reading ? .english : .chinese, targetLanguage: reading ? .chinese : .english,
            caret: .zero, isExpanded: expanded, isGenerating: false, message: "", previousTranslation: nil, shortcutLabel: "",
            units: reading ? [] : [HomeLearningDemoFixtures.unit], unitStage: .ready, targetIsSelection: reading,
            canReplace: !reading && editorText.contains(HomeLearningDemoFixtures.source),
            readingSource: reading ? readingSource : nil)
        if reading, readingSource == .pointer {
            value.vocabularyContext = .init(id: HomeLearningDemoFixtures.documentID, text: HomeLearningDemoFixtures.translation,
                translation: HomeLearningDemoFixtures.source,
                ranges: [.init((HomeLearningDemoFixtures.translation as NSString).range(of: "posted"))],
                completeness: .sentence, meaning: "", createdAt: Date())
        }
        return value
    }
    var currentCapture: VocabularyCapture {
        (lookupVisible ? dictionary.favoriteCapture : nil) ?? VocabularyCaptureFactory.preview(presentation)
            ?? HomeLearningDemoFixtures.capture
    }
    var selectedEntry: VocabularyEntry? { store.entries.first { $0.id == bookSelection?.entryID } }
    var selectedSense: VocabularySense? { selectedEntry?.senses.first { $0.id == bookSelection?.senseID } }

    func prepare() async {
        if let preparation { await preparation.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            for capture in HomeLearningDemoFixtures.seedCaptures { await self.store.save(capture) }
            self.ready = true
        }
        preparation = task
        await task.value
    }

    func select(_ scene: HomeLearningScene) {
        pause(); work?.cancel(); revision = UUID()
        dictionary.close(); explanation.cancel(); speech.stop(); notebook.cancel()
        self.scene = scene; step = 0; expanded = false; cardVisible = true; lookupVisible = false
        favoriteMenuPresented = false; dictionaryMenuPresented = false; bookSelection = nil; ankiDestinationShown = false
        readingSource = .selection; manuallyControlled = false; previewBack = false; reviewFailure = nil
        editorText = "谢谢你的帮助。" + HomeLearningDemoFixtures.source + "我们下周再确认。"
        explanation.setTarget(LearningExplanationPolicy.input(VocabularyCaptureFactory.preview(presentation)
            ?? HomeLearningDemoFixtures.capture))
        executeCurrent()
    }
    func next() { go(to: min(step + 1, scene.steps.count - 1)) }
    func previous() { go(to: max(step - 1, 0)) }
    func go(to index: Int) {
        pause(); manuallyControlled = true
        step = min(max(index, 0), scene.steps.count - 1)
        executeCurrent()
    }
    func replay() { select(scene); play() }
    func hover(_ entering: Bool, reduceMotion: Bool) {
        if entering, !manuallyControlled, !reduceMotion { play(hovered: true) }
        if !entering, hoveredPlayback { pause() }
    }
    func play(hovered: Bool = false) {
        pause(); hoveredPlayback = hovered; isPlaying = true
        if !hovered { manuallyControlled = true }
        executeCurrent()
        playback = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3.5)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if self.step == self.scene.steps.count - 1 { self.pause(); return }
                self.step += 1; self.executeCurrent()
            }
        }
    }
    func pause() {
        playback?.cancel(); playback = nil; isPlaying = false; hoveredPlayback = false
        work?.cancel(); work = nil; revision = UUID()
    }
    /// An actual click or native graph gesture retires the scripted step as well as the timer.
    /// Otherwise a delayed source-selection example could overwrite the user's own choice.
    func interact() { pause(); manuallyControlled = true }
    func stop() {
        pause(); work?.cancel(); revision = UUID(); favoriteMenuPresented = false; dictionaryMenuPresented = false
        dictionary.close(); explanation.cancel(); speech.stop(); notebook.cancel()
    }
    func replace() {
        interact()
        replaceSource()
        if let index = scene.steps.firstIndex(of: .replace) { step = index }
    }
    private func replaceSource() {
        guard presentation.canReplace, let range = editorText.range(of: HomeLearningDemoFixtures.source) else { return }
        editorText.replaceSubrange(range, with: HomeLearningDemoFixtures.translation)
    }
    func dismissCard() {
        interact(); hideCard()
    }
    private func hideCard() {
        cardVisible = false; lookupVisible = false
        dictionary.close(); explanation.cancel(); speech.stop()
    }
    func openLookup(_ requestedUnit: LearningUnit? = nil) {
        interact(); showLookup(requestedUnit)
    }
    private func showLookup(_ requestedUnit: LearningUnit? = nil) {
        let unit = requestedUnit ?? HomeLearningDemoFixtures.unit
        lookupVisible = true; expanded = false
        let original = unit.ranges.contains { range in
            VocabularyPolicy.valid(range, in: presentation.source)
                && (presentation.source as NSString).substring(with: range) == unit.surface
        }
        let capture = VocabularyCaptureFactory.unit(unit, in: presentation, original: original) ?? HomeLearningDemoFixtures.capture
        dictionary.open(unit, documentID: HomeLearningDemoFixtures.documentID, language: capture.language,
            speechContext: capture.example?.text, vocabularyCapture: capture)
    }
    func selectSense(_ selection: VocabularySelection?) {
        interact(); bookSelection = selection
        notebook.select(selectedEntry, senseID: selection?.senseID)
    }
    /// A learner may reach Anki after saving the expression before its explanation arrived.
    /// Resolve that exact usage, fill only its still-empty sample meaning through the normal
    /// annotation API, and select it explicitly instead of assuming the first sense is usable.
    private func reviewSelection() async -> VocabularyExplanationDestination? {
        let capture = HomeLearningDemoFixtures.capture
        await store.save(capture)
        guard let destination = store.explanationDestination(capture),
              let entry = store.entries.first(where: { $0.id == destination.entryID }),
              let sense = entry.senses.first(where: { $0.id == destination.senseID }),
              let example = sense.examples.first(where: { $0.id == destination.exampleID }) else { return nil }
        if example.meaning.isEmpty, example.meaningOrigin != .user {
            let input = LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, sense: sense, example: example))
            await store.saveExplanation(HomeLearningDemoFixtures.record(input))
        }
        return destination
    }
    func prepareReview() async {
        guard let destination = await reviewSelection(),
              let entry = store.entries.first(where: { $0.id == destination.entryID }),
              let sense = entry.senses.first(where: { $0.id == destination.senseID }) else { return }
        if ankiSession?.entryID == entry.id, ankiSession?.senseID == sense.id { return }
        let session = AnkiReviewSession(controller: review, entry: entry, sense: sense, cardID: cardID)
        session.plan.exampleID = destination.exampleID
        ankiSession = session
        await session.load()
    }
    func sendCard() async {
        interact()
        guard let ankiSession else { return }
        if await ankiSession.send(), let index = scene.steps.firstIndex(of: .addAnki) { step = index }
    }
    func reviewCard() async {
        interact()
        guard let binding = ankiSession?.binding, binding.noteID != nil else { return }
        reviewFailure = await review.reviewDeck(binding)
        ankiDestinationShown = reviewFailure == nil
    }
    func useReadingSource(_ source: LearningReadingSource) {
        interact(); readingSource = source; cardVisible = false; lookupVisible = false; expanded = false
        explanation.setTarget(LearningExplanationPolicy.input(currentCapture))
    }
    func showReadingTranslation() {
        interact(); cardVisible = true; lookupVisible = false
        explanation.setTarget(LearningExplanationPolicy.input(currentCapture))
    }

    private func executeCurrent() {
        work?.cancel(); revision = UUID(); favoriteMenuPresented = false; dictionaryMenuPresented = false
        speech.stop(); bookSelection = nil
        let revision = revision, action = action
        work = Task { [weak self] in
            guard let self else { return }
            await self.prepare()
            guard !Task.isCancelled, self.revision == revision else { return }
            self.stage(action)
            switch action {
            case .explain:
                if self.lookupVisible { self.dictionary.explanation.regenerate() } else {
                    self.explanation.explain(refresh: true)
                }
            case .favorite, .favoriteMenu: await self.demonstrateFavorite(action, revision: revision)
            case .sources: await self.demonstrateSource(revision: revision)
            case .replace, .dismiss: await self.demonstrateCardAction(action, revision: revision)
            case .sense: self.demonstrateSense()
            case .layout, .layoutBack, .addAnki, .reviewAnki:
                await self.demonstrateAnki(action, revision: revision)
            default: break
            }
        }
    }

    private func demonstrateSense() {
        guard let bank = store.entries.first(where: { $0.expression == "bank" }), let sense = bank.senses.first else { return }
        bookSelection = .init(entryID: bank.id, senseID: sense.id)
        notebook.select(bank, senseID: sense.id)
        pause() // The real detail sheet waits for the user to finish reading.
    }

    private func demonstrateCardAction(_ action: HomeLearningDemoAction, revision: UUID) async {
        do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
        guard !Task.isCancelled, self.revision == revision else { return }
        if action == .replace { replaceSource() } else { hideCard() }
    }

    private func demonstrateFavorite(_ action: HomeLearningDemoAction, revision: UUID) async {
        await store.save(currentCapture)
        guard !Task.isCancelled, self.revision == revision else { return }
        favoriteMenuPresented = action == .favoriteMenu
    }

    private func demonstrateSource(revision: UUID) async {
        dictionary.selectPage(.dictionary); dictionaryMenuPresented = true
        do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
        guard !Task.isCancelled, self.revision == revision, dictionaryMenuPresented else { return }
        dictionary.selectSource(dictionary.selectedSource == .system ? .bundled : .system)
        dictionaryMenuPresented = false
    }

    private func demonstrateAnki(_ action: HomeLearningDemoAction, revision: UUID) async {
        await prepareReview()
        guard !Task.isCancelled, self.revision == revision, let session = ankiSession else { return }
        if action == .addAnki { _ = await session.send() }
        guard action == .reviewAnki else { return }
        if session.binding?.noteID == nil { _ = await session.send() }
        guard !Task.isCancelled, self.revision == revision, let binding = session.binding else { return }
        reviewFailure = await review.reviewDeck(binding)
        guard !Task.isCancelled, self.revision == revision else { return }
        ankiDestinationShown = reviewFailure == nil
    }

    /// Each step reconstructs its prerequisites. Jumping directly to Dictionary or Anki therefore
    /// works just like advancing in order, and Previous does not toggle an already expanded card.
    private func stage(_ action: HomeLearningDemoAction) {
        if scene == .reading {
            let priorSources = scene.steps.prefix(step + 1)
            readingSource = .selection
            if priorSources.contains(.pointer) { readingSource = .pointer }
            if priorSources.contains(.capture) { readingSource = .screenshot }
        }
        cardVisible = ![.select, .pointer, .capture].contains(action)
        if scene == .lookup {
            if dictionary.unit == nil { showLookup() }
            lookupVisible = true
            dictionary.selectPage([.dictionary, .sources].contains(action) ? .dictionary : .contextual)
        } else { lookupVisible = false }
        expanded = [.expand, .explain].contains(action)
        if action == .preview || action == .collapse { expanded = false }
        if action != .dismiss {
            editorText = "谢谢你的帮助。" + HomeLearningDemoFixtures.source + "我们下周再确认。"
        }
        stageNotebook(action)
        if action == .layout || action == .layoutBack { previewBack = action == .layoutBack }
        // Hover playback points at the speaker; sound starts only through the real button.
        // No synthetic waveform or playback state is drawn in place of the actual controller.
        if !lookupVisible { explanation.setTarget(LearningExplanationPolicy.input(currentCapture)) }
    }
    private func stageNotebook(_ action: HomeLearningDemoAction) {
        if action == .list {
            bookMode = "list"
            expandedHeadwords = Set(store.entries.filter { $0.expression == "bank" }.map(\.id))
        }
        if action == .graph { bookMode = "graph"; graph.collapse() }
        if action == .headword {
            bookMode = "graph"
            if let bank = store.entries.first(where: { $0.expression == "bank" }), !graph.expanded.contains(bank.id) {
                graph.toggle(bank.id)
            }
        }
    }

}
