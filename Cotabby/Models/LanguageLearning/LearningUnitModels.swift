import Foundation

/// A click target in one fixed translation. It is independent of meaning correspondence: a
/// correspondence may include several units, and a pattern may have separated fixed parts.
/// Recognition owns exact ranges; presentation supplies neutral marks until alignment arrives.
nonisolated struct LearningUnit: Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case word, expression, pattern }
    let id: Int
    let surface: String
    let query: String
    let kind: Kind
    let ranges: [NSRange]
    let words: [LearningDictionaryWord]
    var entryID: String?

    static func word(_ word: LearningDictionaryWord) -> Self {
        .init(id: word.range.location, surface: word.text, query: word.text, kind: .word,
              ranges: [word.range], words: [word])
    }
}

nonisolated enum LearningUnitStage: Equatable, Sendable { case pending, ready, failed }

/// Recognition and lookup share a resource, not a success condition. A recognized expression
/// stays intact even if its dictionary query has no entry. These values contain no editor data.
nonisolated struct LearningLexiconEntry: Codable, Equatable, Sendable {
    struct Sense: Codable, Equatable, Sendable {
        let partOfSpeech: String
        let definitions: [String]
        let labels: [String]
    }
    let id: String
    let language: String
    let headword: String
    let forms: [String]
    let senses: [Sense]
    let sourceURL: String
    var phonetics: [String]?
    var examples: [String]?
    var sourceName: String?
    var licenseURL: String?
    var licenseName: String?
}

nonisolated struct LearningLexiconResource: Codable, Sendable {
    let version: String
    let attribution: String
    let licenseURL: String
    let entries: [LearningLexiconEntry]
}

/// Sources return content rather than presenting windows. Bundled entries retain their senses
/// and attribution; the public Dictionary Services API supplies plain text without invented
/// phonetics or sense structure. A miss stays distinct from an unavailable source.
nonisolated enum LearningDictionaryResult: Equatable, Sendable {
    case entries([LearningLexiconEntry])
    case systemText(String)
    case article(LearningDictionaryArticle)
    case website(URL)
    case notFound
}

nonisolated protocol LearningUnitRecognizing: Sendable {
    func recognize(_ translation: String, language: LearningLanguage) async throws -> [LearningUnit]
}

nonisolated protocol LearningDictionaryProviding: Sendable {
    func lookup(_ query: String, language: LearningLanguage, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult
    func resource(_ path: String, libraryID: UUID, configuration: LearningDictionaryConfiguration) async throws -> DictionaryResource?
}

extension LearningDictionaryProviding {
    nonisolated func resource(_ path: String, libraryID: UUID,
                              configuration: LearningDictionaryConfiguration) async throws -> DictionaryResource? { nil }
}
