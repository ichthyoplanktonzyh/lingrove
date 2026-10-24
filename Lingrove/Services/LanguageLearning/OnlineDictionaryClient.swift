import Foundation

/// A deliberately fixed English API, used only after its source has been enabled. Its request
/// contains the lookup term alone. Redirects, cookies, caches and remote pronunciation audio
/// are not part of this boundary; all pronunciation still goes through the shared TTS service.
nonisolated struct OnlineDictionaryClient: Sendable {
    static func url(for query: String) -> URL? {
        DictionaryWebsitePolicy.url(template: "https://api.dictionaryapi.dev/api/v2/entries/en/{query}", query: query)
    }

    func lookup(_ query: String) async throws -> LearningDictionaryResult {
        guard let url = Self.url(for: query) else { return .notFound }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: LearningEndpointSession(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw DictionaryServiceFailure.unavailable }
        if response.statusCode == 404 { return .notFound }
        guard response.statusCode == 200, response.expectedContentLength <= 1_000_000 else {
            throw DictionaryServiceFailure.unavailable
        }
        var data = Data()
        for try await byte in stream {
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard data.count < 1_000_000 else { throw DictionaryServiceFailure.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> LearningDictionaryResult {
        guard data.count <= 1_000_000 else { throw DictionaryServiceFailure.tooLarge }
        let records = try JSONDecoder().decode([Entry].self, from: data)
        let entries = records.prefix(16).enumerated().map { index, entry in
            LearningLexiconEntry(id: "online-\(index)-\(entry.word)", language: "en", headword: entry.word, forms: [],
                senses: entry.meanings.prefix(32).map { meaning in
                    .init(partOfSpeech: meaning.partOfSpeech,
                          definitions: meaning.definitions.prefix(32).map(\.definition), labels: [])
                }, sourceURL: entry.sourceUrls?.first(where: { DictionaryLinkPolicy.externalURL($0) != nil }) ?? "https://dictionaryapi.dev/",
                phonetics: Array(Set(entry.phonetics?.compactMap(\.text) ?? [])).sorted(),
                examples: Array(entry.meanings.flatMap(\.definitions).compactMap(\.example).prefix(16)),
                sourceName: "Free Dictionary API",
                licenseURL: entry.license?.url ?? "", licenseName: entry.license?.name ?? "")
        }
        return entries.isEmpty ? .notFound : .entries(entries)
    }

    private struct Entry: Decodable {
        let word: String
        let phonetics: [Phonetic]?
        let meanings: [Meaning]
        let sourceUrls: [String]?
        let license: License?
    }
    private struct Phonetic: Decodable { let text: String? }
    private struct Meaning: Decodable { let partOfSpeech: String; let definitions: [Definition] }
    private struct Definition: Decodable { let definition: String; let example: String? }
    private struct License: Decodable { let name: String; let url: String }
}

nonisolated enum DictionaryServiceFailure: Error, LocalizedError {
    case unavailable, tooLarge, invalidFile
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "This dictionary is unavailable.", table: "Learning")
        case .tooLarge: String(localized: "This dictionary content exceeds the supported size.", table: "Learning")
        case .invalidFile: String(localized: "This dictionary file could not be read. Import it again.", table: "Learning")
        }
    }
}
