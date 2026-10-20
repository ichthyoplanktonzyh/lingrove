import Foundation

/// Durable learning content is independent of translation requests and Anki. The app-owned
/// vocabulary store persists these values; cards supply immutable captures and never AX handles.
nonisolated struct VocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case word, expression, pattern, sentence }
    let id: UUID
    var expression: String
    var dictionaryForm: String
    let language: LearningLanguage
    let kind: Kind
    var meaning: String
    var meaningLanguage: LearningLanguage?
    var note: String
    var tags: [String]
    var definitions: [VocabularyDefinition]
    var examples: [VocabularyExample]
    var isSavedWithoutContext = false
    var standaloneMeanings: [VocabularyMeaning] = []
    var explanations: [LearningExplanationRecord]?
    let createdAt: Date
    var updatedAt: Date
}

/// A word can be saved without sentence context in several translation languages. Keep those
/// translations distinct instead of pretending they are full example-sentence translations.
nonisolated struct VocabularyMeaning: Codable, Equatable, Identifiable, Sendable {
    var text: String
    let language: LearningLanguage?
    var id: String { language?.rawValue ?? "unknown" }
}

/// One encountered usage, including its exact UTF-16 spans. A pattern may have separated fixed
/// parts, so a list of ranges preserves more information than searching for the first word match.
nonisolated struct VocabularyExample: Codable, Equatable, Identifiable, Sendable {
    enum Completeness: String, Codable, Sendable { case sentence, fragment }
    let id: UUID
    var text: String
    var translation: String
    var translationLanguage: LearningLanguage?
    var ranges: [VocabularyTextRange]
    var completeness: Completeness
    var meaning: String
    var meaningLanguage: LearningLanguage?
    var appBundleIdentifier: String?
    let createdAt: Date
    /// Adopting another language changes annotation content, not the identity of the saved usage.
    /// The wrapper distinguishes an originally unknown language from a missing legacy identity.
    struct CaptureIdentity: Codable, Equatable, Sendable { let meaningLanguage: LearningLanguage? }
    var captureIdentity: CaptureIdentity?
}

nonisolated struct VocabularyTextRange: Codable, Equatable, Hashable, Sendable {
    let location: Int
    let length: Int
    init(_ range: NSRange) { location = range.location; length = range.length }
    var nsRange: NSRange { NSRange(location: location, length: length) }
}

/// Dictionary quotations retain their attribution separately from the user's contextual meaning.
/// The system source supplies plain text; bundled quotations keep their source and license URLs.
nonisolated struct VocabularyDefinition: Codable, Equatable, Sendable {
    let text: String
    let source: String
    let sourceURL: String
    let licenseURL: String
    var licenseName: String?
}

/// Short-lived card input. It is copied with the displayed sentence, so saving never rereads
/// whichever editor happens to be focused after the user clicks a nonactivating card.
nonisolated struct VocabularyCapture: Equatable, Sendable {
    let expression: String
    let dictionaryForm: String
    let language: LearningLanguage
    let kind: VocabularyEntry.Kind
    var meaning = ""
    var meaningLanguage: LearningLanguage?
    var example: VocabularyExample?
    var definitions: [VocabularyDefinition] = []
    var explanation: LearningExplanationRecord?
}

/// Versioned JSON is also the lossless backup format. Unknown versions fail closed instead of
/// silently replacing a newer notebook with an empty archive.
nonisolated struct VocabularyDocument: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var entries: [VocabularyEntry] = []
}

nonisolated struct VocabularySnapshot: Sendable {
    let revision: UInt64
    let document: VocabularyDocument
}

extension VocabularyEntry {
    nonisolated private enum CodingKeys: String, CodingKey {
        case id, expression, dictionaryForm, language, kind, meaning, meaningLanguage
        case note, tags, definitions, examples, isSavedWithoutContext, standaloneMeanings, explanations, createdAt, updatedAt
    }

    /// Earlier schema-v1 exports did not distinguish a contextless save from saved examples.
    /// Decode the missing flag from the old content rather than stranding an otherwise valid book.
    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        expression = try values.decode(String.self, forKey: .expression)
        dictionaryForm = try values.decode(String.self, forKey: .dictionaryForm)
        language = try values.decode(LearningLanguage.self, forKey: .language)
        kind = try values.decode(Kind.self, forKey: .kind)
        meaning = try values.decode(String.self, forKey: .meaning)
        meaningLanguage = try values.decodeIfPresent(LearningLanguage.self, forKey: .meaningLanguage)
        note = try values.decode(String.self, forKey: .note)
        tags = try values.decode([String].self, forKey: .tags)
        definitions = try values.decode([VocabularyDefinition].self, forKey: .definitions)
        examples = try values.decode([VocabularyExample].self, forKey: .examples)
        isSavedWithoutContext = try values.decodeIfPresent(Bool.self, forKey: .isSavedWithoutContext) ?? examples.isEmpty
        standaloneMeanings = try values.decodeIfPresent([VocabularyMeaning].self, forKey: .standaloneMeanings) ??
            (isSavedWithoutContext ? [VocabularyMeaning(text: meaning, language: meaningLanguage)] : [])
        explanations = try values.decodeIfPresent([LearningExplanationRecord].self, forKey: .explanations)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

/// Storage destination is separate from semantic input: two saved translations can share one
/// explanation while still owning independently editable meanings.
nonisolated struct VocabularyExplanationDestination: Equatable, Sendable {
    let entryID: UUID
    let exampleID: UUID?
}
