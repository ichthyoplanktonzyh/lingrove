import Foundation

/// The composition root shares this router across cards. Each request carries an immutable
/// settings snapshot, so a source cannot accidentally inherit permissions from another query.
actor LearningDictionaryRouter: LearningDictionaryProviding {
    let lexicon: LearningLexiconService
    let mdict: MDictLibraryService
    private let system = SystemDictionaryArticleService()
    private let online = OnlineDictionaryClient()

    init(lexicon: LearningLexiconService, mdict: MDictLibraryService = MDictLibraryService()) {
        self.lexicon = lexicon
        self.mdict = mdict
    }

    func lookup(_ query: String, language: LearningLanguage, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        try Task.checkCancellation()
        guard DictionaryContentPolicy.validQuery(query), configuration.enabled.contains(source) else { return .notFound }
        switch source.kind {
        case .bundled:
            return try await lexicon.lookup(query, language: language, expression: expression, source: source)
        case .system:
            if configuration.systemFormat == .formatted, let article = try? await system.lookup(query) {
                try Task.checkCancellation()
                return .article(article)
            }
            try Task.checkCancellation()
            return try await lexicon.lookup(query, language: language, expression: expression, source: source)
        case .mdict:
            guard let library = configuration.libraries.first(where: { $0.source == source }) else { return .notFound }
            return try await mdict.lookup(query, library: library)
        case .online:
            guard language == .english else { return .notFound }
            return try await online.lookup(query)
        case .website:
            guard let website = configuration.websites.first(where: { $0.source == source }),
                  let url = DictionaryWebsitePolicy.url(template: website.template, query: query) else { return .notFound }
            return .website(url)
        }
    }

    func resource(_ path: String, libraryID: UUID, configuration: LearningDictionaryConfiguration) async throws -> DictionaryResource? {
        guard configuration.enabled.contains(.mdict(libraryID)),
              let library = configuration.libraries.first(where: { $0.id == libraryID }) else { return nil }
        return try await mdict.resource(path, library: library)
    }
}
