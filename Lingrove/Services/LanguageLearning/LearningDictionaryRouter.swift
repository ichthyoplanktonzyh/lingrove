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

    func lookup(_ query: String, language: LearningLanguage?, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        try Task.checkCancellation()
        guard DictionaryContentPolicy.validQuery(query), configuration.sources(for: language).contains(source) else { return .notFound }
        switch source.kind {
        case .bundled:
            return try await lexicon.lookup(query, language: language, expression: expression, source: source)
        case .system:
            return try await systemLookup(query, language: language, expression: expression, configuration: configuration)
        case .mdict:
            guard let library = configuration.libraries.first(where: { $0.source == source }) else { return .notFound }
            return try await mdict.lookup(query, library: library)
        case .online:
            guard language == nil || language == .english else { return .notFound }
            return try await online.lookup(query)
        case .website:
            guard let website = configuration.websites.first(where: { $0.source == source }),
                  let url = DictionaryWebsitePolicy.url(template: website.template, query: query) else { return .notFound }
            return .website(url)
        }
    }

    private func systemLookup(_ query: String, language: LearningLanguage?, expression: Bool,
                              configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        if var article = try? await system.lookup(query, language: language,
                                                  definitionLanguage: configuration.preferredDefinitionLanguage) {
            try Task.checkCancellation()
            guard !article.text.isEmpty || !article.html.isEmpty else { return .notFound }
            // Both presentation formats use the same language-selected book. Plain text is
            // rendered by Text, never interpreted as HTML markup.
            if configuration.systemFormat == .text { article.html = "" }
            return .article(article)
        }
        try Task.checkCancellation()
        // The public NULL-dictionary query cannot select an entry language. If the helper
        // cannot enumerate language metadata, another enabled provider is the safe fallback.
        throw DictionaryServiceFailure.unavailable
    }

    func resource(_ path: String, libraryID: UUID, configuration: LearningDictionaryConfiguration) async throws -> DictionaryResource? {
        guard configuration.enabled.contains(.mdict(libraryID)),
              let library = configuration.libraries.first(where: { $0.id == libraryID }) else { return nil }
        return try await mdict.resource(path, library: library)
    }
}
