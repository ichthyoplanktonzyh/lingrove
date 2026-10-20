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
    var meaningOrigin: VocabularyMeaningOrigin = .captured
    var note: String
    var tags: [String]
    var examples: [VocabularyExample]
    var isSavedWithoutContext = false
    var standaloneMeanings: [VocabularyMeaning] = []
    var explanations: [LearningExplanationRecord]?
    let createdAt: Date
    var updatedAt: Date
}

/// The archive records who owns a meaning, independently of its text. Model refreshes may
/// replace captured/AI drafts, while an explicit edit or adoption transfers ownership to the user.
nonisolated enum VocabularyMeaningOrigin: String, Codable, Equatable, Sendable { case captured, ai, user }

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
    var meaningOrigin: VocabularyMeaningOrigin = .captured
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
    var explanation: LearningExplanationRecord?
}

/// Versioned JSON is also the lossless backup format. Unknown versions fail closed instead of
/// silently replacing a newer notebook with an empty archive.
nonisolated struct VocabularyDocument: Codable, Equatable, Sendable {
    var schemaVersion = 2
    var entries: [VocabularyEntry] = []
}

nonisolated struct VocabularySnapshot: Sendable {
    let revision: UInt64
    let document: VocabularyDocument
}

/// Storage destination is separate from semantic input: two saved translations can share one
/// explanation while still owning independently editable meanings.
nonisolated struct VocabularyExplanationDestination: Equatable, Sendable {
    let entryID: UUID
    let exampleID: UUID?
}
