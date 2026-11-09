import Foundation

/// A user-authored entry before it has durable IDs. Create sheets own
/// these values; only the archive assigns entry/sense identities and commits them to SQLite.
public nonisolated struct VocabularyEntryInput: Equatable, Sendable {
    public init(expression: String = "", dictionaryForm: String = "", language: LearningLanguage? = .english,
                kind: VocabularyEntry.Kind = .word, meaning: String = "", meaningLanguage: LearningLanguage? = nil,
                note: String = "", tags: [String] = [], example: String = "", exampleTranslation: String = "") {
        self.expression = expression; self.dictionaryForm = dictionaryForm; self.language = language; self.kind = kind
        self.meaning = meaning; self.meaningLanguage = meaningLanguage; self.note = note; self.tags = tags
        self.example = example; self.exampleTranslation = exampleTranslation
    }
    public var expression = ""
    public var dictionaryForm = ""
    public var language: LearningLanguage? = .english
    public var kind: VocabularyEntry.Kind = .word
    public var meaning = ""
    public var meaningLanguage: LearningLanguage?
    public var note = ""
    public var tags: [String] = []
    public var example = ""
    public var exampleTranslation = ""
}

/// Creation acknowledges the newly saved entries and senses.
/// Returning both IDs lets the window reveal a newly added sense or an existing duplicate.
public nonisolated struct VocabularyEntryImportResult: Equatable, Sendable {
    public init() {}
    public var addedEntries = 0
    public var addedSenses = 0
    public var skippedRows = 0
    public var addedExamples = 0
    public var addedTranslations = 0
    /// Re-importing knowledge retained after uncollecting can change membership alone.
    public var selection: VocabularySelection?
    public var hasChanges: Bool { addedSenses > 0 || addedExamples > 0 || addedTranslations > 0 }
}

/// Manual input validation remains separate from filesystem formats. External materials are
/// interpreted by an agent and submitted through explicit sense operations.
public nonisolated enum VocabularyEntryInputError: LocalizedError {
    case invalidInput, translationWithoutExample
    public var errorDescription: String? {
        switch self {
        case .invalidInput: String(localized: "Check the expression, meaning, notes, and tags before saving.", table: "Vocabulary")
        case .translationWithoutExample: String(localized: "Add an example sentence before its translation.", table: "Vocabulary")
        }
    }
}
