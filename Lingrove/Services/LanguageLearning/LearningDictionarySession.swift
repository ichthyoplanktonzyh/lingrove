import Combine
import Foundation
import Logging

/// One nonactivating dictionary panel owns one session. It queries enabled sources in priority
/// order until a hit, or queries just the source explicitly selected in this card. Revisions
/// retire old requests after word/source/settings changes without changing the captured example.
@MainActor
final class LearningDictionarySession: ObservableObject {
    let explanation: LearningExplanationSession
    /// A query owns one target and two independently loaded presentations. Changing tabs is
    /// navigation, not another model request; dictionary sources remain lazy until selected.
    enum Page: Hashable { case contextual, dictionary }
    @Published private(set) var page: Page = .dictionary
    private var dictionaryRequested = false
    enum Content: Equatable {
        case loading
        case result(LearningDictionaryResult)
        case failed(String)
    }
    @Published private(set) var unit: LearningUnit?
    @Published private(set) var documentID: UUID?
    @Published private(set) var selectedWord: LearningDictionaryWord?
    @Published private(set) var referenceQuery: String?
    @Published private(set) var content: Content = .loading
    @Published private(set) var selectedSource: LearningDictionarySource = .bundled
    @Published private(set) var configuration = LearningDictionaryConfiguration()
    /// Captured from the same translation that supplied the unit. It lives only as long as this
    /// session and helps speech resolve short words without reading the editor or definitions.
    private(set) var speechContext: String?
    private(set) var vocabularyCapture: VocabularyCapture?
    private let provider: any LearningDictionaryProviding
    private var language: LearningLanguage?
    private var translationLanguage: LearningLanguage?
    private var validateCapture: () -> Bool = { true }
    /// Target lifetime differs from dictionary request lifetime: source/tab changes keep it,
    /// while navigating to another occurrence or reopening the same spelling retires it.
    private(set) var targetIdentity = UUID()
    private var revision = UUID()
    private var work: Task<Void, Never>?
    private var cache: [String: LearningDictionaryResult] = [:]
    private var cacheOrder: [String] = []
    private var sourceOverride: LearningDictionarySource?
    private var settingsSubscription: AnyCancellable?
    private var explanationSubscription: AnyCancellable?

    init(provider: any LearningDictionaryProviding, settings: LearningDictionarySettings? = nil,
         explanationService: (any LearningExplanationGenerating)? = nil) {
        self.provider = provider
        explanation = LearningExplanationSession(service: explanationService)
        explanationSubscription = explanation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if let settings {
            configuration = settings.configuration
            settingsSubscription = settings.$configuration.dropFirst().sink { [weak self] configuration in
                guard let self else { return }
                self.configuration = configuration
                if let source = self.sourceOverride, !configuration.sources(for: self.language).contains(source) {
                    self.sourceOverride = nil
                }
                self.cache.removeAll()
                self.cacheOrder.removeAll()
                if self.dictionaryRequested { self.requestDictionary() }
            }
        }
    }

    var title: String { referenceQuery ?? selectedWord?.text ?? unit?.surface ?? "" }
    var query: String { referenceQuery ?? selectedWord?.text ?? unit?.query ?? "" }
    var isRelatedEntry: Bool { selectedWord != nil || referenceQuery != nil }
    var sourceName: String {
        availableSources.contains(selectedSource) ? configuration.name(for: selectedSource)
            : String(localized: "No matching dictionary", table: "Learning")
    }
    var requestIdentity: UUID { revision }

    /// The opening language is captured with the active unit. The card uses it for the component
    /// words' visual reading order without inferring direction from the UI locale or term text.
    var contentLanguage: LearningLanguage? { language }
    var availableSources: [LearningDictionarySource] { configuration.sources(for: language) }
    func name(for source: LearningDictionarySource) -> String { configuration.name(for: source) }
    func languageLabel(for source: LearningDictionarySource) -> String? {
        if source.kind == .mdict, configuration.languages(for: source) == nil {
            return DictionaryLanguagePair().label
        }
        return configuration.languages(for: source)?.label
    }
    var definitionLanguageLabel: String? {
        if case .loading = content { return nil }
        let pair: DictionaryLanguagePair?
        if case .result(.article(let article)) = content { pair = article.languages } else {
            pair = configuration.languages(for: selectedSource)
        }
        guard let pair, let definition = pair.definition else { return nil }
        return DictionaryLanguagePair(entry: language, definition: definition).label
    }
    func resourceLoader(for libraryID: UUID?) -> DictionaryResourceLoader {
        let provider = provider, configuration = configuration
        return { path in
            guard let libraryID else { return nil }
            return try? await provider.resource(path, libraryID: libraryID, configuration: configuration)
        }
    }
    var contextExample: VocabularyExample? { displayedCapture?.example }

    private var activeCapture: VocabularyCapture? {
        if let referenceQuery {
            return .init(expression: referenceQuery, dictionaryForm: referenceQuery, language: language,
                         kind: LearningUnitPolicy.words(in: referenceQuery, language: language).count == 1 ? .word : .expression)
        }
        let fallback = unit.map { unit in
            VocabularyCapture(expression: unit.kind == .pattern ? unit.query : unit.surface,
                dictionaryForm: unit.query, language: language,
                kind: unit.kind == .word ? .word : unit.kind == .pattern ? .pattern : .expression,
                example: speechContext.flatMap { VocabularyPolicy.example(text: $0, ranges: unit.ranges, language: language) })
        }
        guard let capture = vocabularyCapture ?? fallback else { return nil }
        guard let selectedWord, let unit else { return capture }
        return VocabularyCaptureFactory.component(selectedWord, unit: unit, capture: capture)
    }

    var favoriteCapture: VocabularyCapture? {
        // A click during the initial request must not save an empty pre-result usage that
        // silently misses the pair published a moment later. Existing results remain saveable.
        guard !(explanation.isLookup && explanation.isGenerating && explanation.lookupRecord == nil) else { return nil }
        return displayedCapture
    }

    /// Presentation keeps the existing toolbar visible while its first pair is loading. The
    /// separate favorite gate disables saving until these displayed values form a complete pair.
    var displayedCapture: VocabularyCapture? {
        guard var capture = activeCapture else { return nil }
        capture.allowsExplanationEnrichment = !explanation.isLookup
        if let basic = explanation.lookupRecord {
            capture.meaning = basic.result.meaning
            capture.meaningLanguage = basic.language
            capture.example?.meaning = basic.result.meaning
            capture.example?.meaningLanguage = basic.language
            capture.example?.meaningOrigin = .ai
            if let example = capture.example, !example.translation.isEmpty,
               example.translation != basic.result.sentenceTranslation {
                let previous = VocabularyMeaning(text: example.translation, language: example.translationLanguage)
                if !example.translationVariants.contains(previous) { capture.example?.translationVariants.append(previous) }
            }
            capture.example?.translation = basic.result.sentenceTranslation
            capture.example?.translationLanguage = basic.input.translationLanguage
        }
        capture.explanation = explanation.record
        return capture
    }

    func open(_ unit: LearningUnit, documentID: UUID, language: LearningLanguage?, speechContext: String? = nil,
              vocabularyCapture: VocabularyCapture? = nil, translationLanguage: LearningLanguage? = nil,
              validateCapture: @escaping () -> Bool = { true }) {
        close()
        self.translationLanguage = translationLanguage
        self.validateCapture = validateCapture
        self.unit = unit
        self.documentID = documentID
        self.language = language
        self.speechContext = speechContext
        self.vocabularyCapture = vocabularyCapture
        beginQuery()
    }

    func select(_ word: LearningDictionaryWord) {
        guard let unit, unit.words.contains(word) else { return }
        selectedWord = word
        referenceQuery = nil
        sourceOverride = nil
        beginQuery()
    }

    func returnToExpression() {
        guard unit != nil else { return }
        selectedWord = nil
        referenceQuery = nil
        sourceOverride = nil
        beginQuery()
    }

    func selectSource(_ source: LearningDictionarySource) {
        guard unit != nil, availableSources.contains(source) else { return }
        sourceOverride = source
        page = .dictionary
        requestDictionary()
    }

    /// A dictionary cross-reference need not occur in the captured sentence. Preserve the home
    /// unit for Back, but do not attach an unrelated original example to this new expression.
    func followReference(_ query: String) {
        guard unit != nil, DictionaryContentPolicy.validQuery(query) else { return }
        referenceQuery = query
        selectedWord = nil
        sourceOverride = selectedSource
        beginQuery()
    }

    func close() {
        targetIdentity = UUID()
        explanation.clear()
        dictionaryRequested = false
        revision = UUID()
        work?.cancel(); work = nil
        unit = nil; documentID = nil; selectedWord = nil
        referenceQuery = nil
        speechContext = nil
        vocabularyCapture = nil
        translationLanguage = nil
        validateCapture = { true }
        sourceOverride = nil
        content = .loading
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func isCurrent(_ id: UUID) -> Bool {
        !Task.isCancelled && revision == id && unit != nil
    }

    private func lookup(_ text: String, language: LearningLanguage?, expression: Bool,
                        source: LearningDictionarySource,
                        requestID: UUID) async throws -> LearningDictionaryResult {
        let key = source.rawValue + ":" + (language?.rawValue ?? "und") + ":" + String(expression) + ":" + text
        if let cached = cache[key] { return cached }
        LingroveLogger.learning.debug("Dictionary lookup", metadata: [
            "stage": "dictionary-lookup", "request_id": .string(requestID.uuidString),
            "dictionary_source": .string(source.rawValue), "query_characters": .stringConvertible(text.count),
            "entry_language": .string((language?.rawValue ?? "und")),
            "preferred_definition_language": .string(configuration.preferredDefinitionLanguage.rawValue)
        ])
        let result = try await provider.lookup(text, language: language, expression: expression,
                                               source: source, configuration: configuration)
        guard isCurrent(requestID) else { throw CancellationError() }
        cache[key] = result
        cacheOrder.append(key)
        while cacheOrder.count > 32 || cache.values.reduce(0, { $0 + $1.estimatedBytes }) > 8 * 1024 * 1024 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return result
    }

    func selectPage(_ page: Page, targetIdentity: UUID? = nil) {
        guard unit != nil, targetIdentity == nil || targetIdentity == self.targetIdentity, self.page != page else { return }
        self.page = page
        if page == .dictionary, !dictionaryRequested { requestDictionary() }
    }

    private func beginQuery() {
        targetIdentity = UUID()
        revision = UUID()
        work?.cancel(); work = nil
        content = .loading
        dictionaryRequested = false
        if let service = explanation.service as? any LearningLookupGenerating, let capture = activeCapture {
            explanation.setLookupTarget(.init(target: LearningExplanationPolicy.input(capture),
                translationLanguage: translationLanguage ?? capture.example?.translationLanguage
                    ?? service.language,
                referenceTranslation: capture.example?.translation ?? ""), requestID: LearningRequestTrace.requestID)
        } else { explanation.setTarget(activeCapture.map(LearningExplanationPolicy.input)) }
        explanation.isTargetCurrent = validateCapture
        page = explanation.isConfigured ? .contextual : .dictionary
        if page == .dictionary { requestDictionary() } else if explanation.isConfigured {
            if explanation.isLookup { explanation.loadLookup() } else { explanation.explain() }
        }
    }

    private func requestDictionary() {
        dictionaryRequested = true
        revision = UUID()
        work?.cancel(); work = nil
        guard let unit else { return }
        let id = revision, text = query, language = language
        let expression = referenceQuery.map { LearningUnitPolicy.words(in: $0, language: language).count > 1 }
            ?? (selectedWord == nil && unit.kind != .word)
        let configuration = configuration
        let automatic = configuration.automaticSources(for: language)
        let websites = availableSources.filter { $0.kind == .website }
        let sources = sourceOverride.map { [$0] } ?? (automatic.isEmpty ? Array(websites.prefix(1)) : automatic)
        selectedSource = sources.first ?? .bundled
        content = .loading
        work = Task { [weak self] in
            var failure: (source: LearningDictionarySource, message: String)?
            for source in sources {
                guard let self, self.isCurrent(id) else { return }
                do {
                    let result = try await self.lookup(text, language: language, expression: expression,
                        source: source, requestID: id)
                    guard self.isCurrent(id) else { return }
                    if result != .notFound {
                        self.selectedSource = source
                        self.content = .result(result)
                        self.work = nil
                        return
                    }
                } catch {
                    guard self.isCurrent(id) else { return }
                    // One unavailable source must not hide a successful fallback. If no source
                    // succeeds, retain the error rather than presenting a corrupt resource as a miss.
                    if failure == nil { failure = (source, error.localizedDescription) }
                }
            }
            guard let self, self.isCurrent(id) else { return }
            if let failure { self.selectedSource = failure.source; self.content = .failed(failure.message) } else {
                self.content = .result(.notFound)
            }
            self.work = nil
        }
    }
}
