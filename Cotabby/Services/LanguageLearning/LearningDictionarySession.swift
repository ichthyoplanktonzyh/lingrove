import Combine
import Foundation
import Logging

/// One nonactivating dictionary panel owns one session. It queries enabled sources in priority
/// order until a hit, or queries just the source explicitly selected in this card. Revisions
/// retire old requests after word/source/settings changes without changing the captured example.
@MainActor
final class LearningDictionarySession: ObservableObject {
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
    private var language: LearningLanguage = .english
    private var revision = UUID()
    private var work: Task<Void, Never>?
    private var cache: [String: LearningDictionaryResult] = [:]
    private var cacheOrder: [String] = []
    private var sourceOverride: LearningDictionarySource?
    private var settingsSubscription: AnyCancellable?

    init(provider: any LearningDictionaryProviding, settings: LearningDictionarySettings? = nil) {
        self.provider = provider
        if let settings {
            configuration = settings.configuration
            settingsSubscription = settings.$configuration.dropFirst().sink { [weak self] configuration in
                guard let self else { return }
                self.configuration = configuration
                if let source = self.sourceOverride, !configuration.enabled.contains(source) { self.sourceOverride = nil }
                self.cache.removeAll()
                self.cacheOrder.removeAll()
                self.request()
            }
        }
    }

    var title: String { referenceQuery ?? selectedWord?.text ?? unit?.surface ?? "" }
    var query: String { referenceQuery ?? selectedWord?.text ?? unit?.query ?? "" }
    var isRelatedEntry: Bool { selectedWord != nil || referenceQuery != nil }
    var sourceName: String { configuration.name(for: selectedSource) }
    var requestIdentity: UUID { revision }

    /// The opening language is captured with the active unit. The card uses it for the component
    /// words' visual reading order without inferring direction from the UI locale or term text.
    var contentLanguage: LearningLanguage { language }
    var availableSources: [LearningDictionarySource] { configuration.activeSources }
    func name(for source: LearningDictionarySource) -> String { configuration.name(for: source) }
    func resourceLoader(for libraryID: UUID?) -> DictionaryResourceLoader {
        let provider = provider, configuration = configuration
        return { path in
            guard let libraryID else { return nil }
            return try? await provider.resource(path, libraryID: libraryID, configuration: configuration)
        }
    }
    var contextExample: VocabularyExample? { activeCapture?.example }

    private var activeCapture: VocabularyCapture? {
        if let referenceQuery {
            return .init(expression: referenceQuery, dictionaryForm: referenceQuery, language: language,
                         kind: LearningUnitPolicy.words(in: referenceQuery, language: language).count == 1 ? .word : .expression)
        }
        guard let capture = vocabularyCapture else { return nil }
        guard let selectedWord, let unit else { return capture }
        return VocabularyCaptureFactory.component(selectedWord, unit: unit, capture: capture)
    }

    var favoriteCapture: VocabularyCapture? {
        guard content != .loading, var capture = activeCapture else { return nil }
        capture.definitions = VocabularyCaptureFactory.definitions(content)
        return capture
    }

    func open(_ unit: LearningUnit, documentID: UUID, language: LearningLanguage, speechContext: String? = nil,
              vocabularyCapture: VocabularyCapture? = nil) {
        close()
        self.unit = unit
        self.documentID = documentID
        self.language = language
        self.speechContext = speechContext
        self.vocabularyCapture = vocabularyCapture
        request()
    }

    func select(_ word: LearningDictionaryWord) {
        guard let unit, unit.words.contains(word) else { return }
        selectedWord = word
        referenceQuery = nil
        sourceOverride = nil
        request()
    }

    func returnToExpression() {
        guard unit != nil else { return }
        selectedWord = nil
        referenceQuery = nil
        sourceOverride = nil
        request()
    }

    func selectSource(_ source: LearningDictionarySource) {
        guard unit != nil, availableSources.contains(source) else { return }
        sourceOverride = source
        request()
    }

    /// A dictionary cross-reference need not occur in the captured sentence. Preserve the home
    /// unit for Back, but do not attach an unrelated original example to this new expression.
    func followReference(_ query: String) {
        guard unit != nil, DictionaryContentPolicy.validQuery(query) else { return }
        referenceQuery = query
        selectedWord = nil
        sourceOverride = selectedSource
        request()
    }

    func close() {
        revision = UUID()
        work?.cancel(); work = nil
        unit = nil; documentID = nil; selectedWord = nil
        referenceQuery = nil
        speechContext = nil
        vocabularyCapture = nil
        sourceOverride = nil
        content = .loading
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func isCurrent(_ id: UUID) -> Bool {
        !Task.isCancelled && revision == id && unit != nil
    }

    private func lookup(_ text: String, language: LearningLanguage, expression: Bool,
                        source: LearningDictionarySource,
                        requestID: UUID) async throws -> LearningDictionaryResult {
        let key = source.rawValue + ":" + language.rawValue + ":" + String(expression) + ":" + text
        if let cached = cache[key] { return cached }
        CotabbyLogger.learning.debug("Dictionary lookup", metadata: [
            "stage": "dictionary-lookup", "request_id": .string(requestID.uuidString),
            "dictionary_source": .string(source.rawValue), "query_characters": .stringConvertible(text.count)
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

    private func request() {
        revision = UUID()
        work?.cancel(); work = nil
        guard let unit else { return }
        let id = revision, text = query, language = language
        let expression = referenceQuery.map { LearningUnitPolicy.words(in: $0, language: language).count > 1 }
            ?? (selectedWord == nil && unit.kind != .word)
        let configuration = configuration
        let automatic = configuration.automaticSources
        let sources = sourceOverride.map { [$0] } ?? (automatic.isEmpty ? Array(configuration.activeSources.prefix(1)) : automatic)
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
