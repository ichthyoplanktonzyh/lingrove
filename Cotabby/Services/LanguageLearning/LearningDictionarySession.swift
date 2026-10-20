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
                self.request()
            }
        }
    }

    var title: String { selectedWord?.text ?? unit?.surface ?? "" }
    var query: String { selectedWord?.text ?? unit?.query ?? "" }

    /// The opening language is captured with the active unit. The card uses it for the component
    /// words' visual reading order without inferring direction from the UI locale or term text.
    var contentLanguage: LearningLanguage { language }
    var availableSources: [LearningDictionarySource] { configuration.activeSources }
    var contextExample: VocabularyExample? { activeCapture?.example }

    private var activeCapture: VocabularyCapture? {
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
        sourceOverride = nil
        request()
    }

    func returnToExpression() {
        guard unit != nil else { return }
        selectedWord = nil
        sourceOverride = nil
        request()
    }

    func selectSource(_ source: LearningDictionarySource) {
        guard unit != nil, availableSources.contains(source) else { return }
        sourceOverride = source
        request()
    }

    func close() {
        revision = UUID()
        work?.cancel(); work = nil
        unit = nil; documentID = nil; selectedWord = nil
        speechContext = nil
        vocabularyCapture = nil
        sourceOverride = nil
        content = .loading
        cache.removeAll()
    }

    private func isCurrent(_ id: UUID) -> Bool {
        !Task.isCancelled && revision == id && unit != nil
    }

    private func lookup(_ text: String, language: LearningLanguage, expression: Bool,
                        source: LearningDictionarySource, requestID: UUID) async throws -> LearningDictionaryResult {
        let key = source.rawValue + ":" + String(expression) + ":" + text
        if let cached = cache[key] { return cached }
        CotabbyLogger.learning.debug("Dictionary lookup", metadata: [
            "stage": "dictionary-lookup", "request_id": .string(requestID.uuidString),
            "dictionary_source": .string(source.rawValue), "query_characters": .stringConvertible(text.count)
        ])
        let result = try await provider.lookup(text, language: language, expression: expression, source: source)
        guard isCurrent(requestID) else { throw CancellationError() }
        cache[key] = result
        return result
    }

    private func request() {
        revision = UUID()
        work?.cancel(); work = nil
        guard let unit else { return }
        let id = revision, text = query, language = language
        let expression = selectedWord == nil && unit.kind != .word
        let sources = sourceOverride.map { [$0] } ?? availableSources
        selectedSource = sources.first ?? .bundled
        content = .loading
        work = Task { [weak self] in
            var failure: (source: LearningDictionarySource, message: String)?
            for source in sources {
                guard let self, self.isCurrent(id) else { return }
                do {
                    let result = try await self.lookup(text, language: language, expression: expression, source: source, requestID: id)
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
