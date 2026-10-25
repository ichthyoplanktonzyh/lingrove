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
    var senses: [VocabularySense]
    let createdAt: Date
    var updatedAt: Date

    /// Read-only projections support headword-wide search and dictionary lookup. Storage and
    /// editing always name a sense; these projections never create a second owner of a usage.
    var examples: [VocabularyExample] { senses.flatMap(\.examples) }
    var explanations: [LearningExplanationRecord]? {
        let records = senses.flatMap { $0.explanations + $0.examples.flatMap(\.explanations) }
        var seen = Set<UUID>()
        let unique = records.filter { seen.insert($0.id).inserted }
        return unique.isEmpty ? nil : unique
    }
}

/// A stable learning identity for one core meaning. The entry groups senses; this value owns
/// its summary, notes and usages and will be the future review/Anki reference. Rewording a
/// summary does not change its UUID. Merged IDs remain resolvable instead of being recycled.
nonisolated struct VocabularySense: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var meaning: String
    var meaningLanguage: LearningLanguage?
    var meaningOrigin: VocabularyMeaningOrigin = .captured
    var note = ""
    var tags: [String] = []
    var examples: [VocabularyExample] = []
    var isSavedWithoutContext = false
    var standaloneMeanings: [VocabularyMeaning] = []
    var explanations: [LearningExplanationRecord] = []
    var alternateMeanings: [VocabularyMeaning] = []
    var mergedFrom: [UUID] = []
    /// Optional so existing v3 notebooks decode without a migration or a library reset.
    var review: VocabularyReview?
    /// Flexible cards have independent review identities. Legacy review records are not migrated.
    var reviewCards: [VocabularyReview]?
    var content: [VocabularyContentBlock]?
    let createdAt: Date
    var updatedAt: Date
    /// Manual/imported meanings need general explanations without claiming the single
    /// context-free favorite slot. Optional keeps existing v3 payloads backward compatible.
    var createdWithoutContext: Bool?
    var supportsGeneralExplanation: Bool { isSavedWithoutContext || createdWithoutContext == true }
}

/// Window navigation and durable destinations use both levels. Sense IDs stay independent of
/// presentation order, labels and generated explanation language.
nonisolated struct VocabularySelection: Equatable, Hashable, Sendable {
    let entryID: UUID
    let senseID: UUID
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
    var translationVariants: [VocabularyMeaning] = []
    var ranges: [VocabularyTextRange]
    var completeness: Completeness
    var meaning: String
    var meaningLanguage: LearningLanguage?
    var meaningOrigin: VocabularyMeaningOrigin = .captured
    var appBundleIdentifier: String?
    let createdAt: Date
    var explanations: [LearningExplanationRecord] = []

    func copiedWithNewID() -> Self {
        .init(id: UUID(), text: text, translation: translation, translationLanguage: translationLanguage,
            translationVariants: translationVariants, ranges: ranges, completeness: completeness, meaning: meaning,
            meaningLanguage: meaningLanguage, meaningOrigin: meaningOrigin, appBundleIdentifier: appBundleIdentifier,
            createdAt: createdAt, explanations: explanations)
    }
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
    /// Supplied only by an explicit notebook destination, never by model-generated text.
    var senseID: UUID?
    /// Explicit notebook senses have a local receipt independent of text equality. Floating
    /// captures leave it nil; this identity is never included in the model's prompt.
    var generalExplanationIdentity: String?
}

/// The immutable notebook value is shared by UI snapshots, backup and JSON interchange. SQLite
/// stores its entities separately; this version describes the portable representation only.
nonisolated struct VocabularyDocument: Codable, Equatable, Sendable {
    var schemaVersion = 3
    var entries: [VocabularyEntry] = []
    var reviewTemplates: [ReviewLayoutTemplate]?
}

nonisolated struct VocabularySnapshot: Sendable {
    let revision: UInt64
    let document: VocabularyDocument
}

/// Storage destination is separate from semantic input: two saved translations can share one
/// explanation while still owning independently editable meanings.
nonisolated struct VocabularyExplanationDestination: Equatable, Sendable {
    let entryID: UUID
    let senseID: UUID
    let exampleID: UUID?
}
