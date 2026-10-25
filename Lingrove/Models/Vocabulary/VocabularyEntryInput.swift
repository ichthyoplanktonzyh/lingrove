import Foundation

/// A user-authored entry before it has durable IDs. Create sheets and word-list previews own
/// these values; only the archive assigns entry/sense identities and commits them to SQLite.
nonisolated struct VocabularyEntryInput: Equatable, Sendable {
    var expression = ""
    var dictionaryForm = ""
    var language: LearningLanguage = .english
    var kind: VocabularyEntry.Kind = .word
    var meaning = ""
    var meaningLanguage: LearningLanguage?
    var note = ""
    var tags: [String] = []
}

/// Import acknowledges what actually changed against the latest notebook, not a stale preview.
/// Returning both IDs lets the window reveal a newly added sense or an existing duplicate.
nonisolated struct VocabularyEntryImportResult: Equatable, Sendable {
    var addedEntries = 0
    var addedSenses = 0
    var skippedRows = 0
    var selection: VocabularySelection?
}

/// The source table keeps physical line numbers for useful errors even with quoted CSV newlines.
/// A preview retains only bounded text, never a file handle or permission-scoped URL.
nonisolated struct VocabularyWordList: Sendable {
    enum Format: Sendable { case csv, text }
    struct Row: Sendable {
        let line: Int
        let cells: [String]
    }
    let format: Format
    let rows: [Row]
    var columnCount: Int { rows.map(\.cells.count).max() ?? 0 }
}

nonisolated enum VocabularyImportField: String, CaseIterable, Sendable {
    case expression, meaning, dictionaryForm, language, kind, meaningLanguage, note, tags

    var label: String {
        switch self {
        case .expression: String(localized: "Expression", table: "Vocabulary")
        case .meaning: String(localized: "Core meaning", table: "Vocabulary")
        case .dictionaryForm: String(localized: "Dictionary form", table: "Vocabulary")
        case .language: String(localized: "Language", table: "Vocabulary")
        case .kind: String(localized: "Entry type", table: "Vocabulary")
        case .meaningLanguage: String(localized: "Meaning language", table: "Vocabulary")
        case .note: String(localized: "Notes", table: "Vocabulary")
        case .tags: String(localized: "Tags", table: "Vocabulary")
        }
    }
}

/// Explicit mappings support headerless lists and third-party column names without guessing
/// which cell is a word. Default language/type apply only when a mapped cell is empty.
nonisolated struct VocabularyWordListConfiguration: Equatable, Sendable {
    var hasHeader = false
    var columns: [VocabularyImportField: Int] = [.expression: 0]
    var language: LearningLanguage = .english
    var kind: VocabularyEntry.Kind = .word
    var meaningLanguage: LearningLanguage?
}

nonisolated struct VocabularyWordListPreview: Sendable {
    let inputs: [VocabularyEntryInput]
    let result: VocabularyEntryImportResult
}

nonisolated enum VocabularyWordListError: LocalizedError {
    case tooLarge, encoding, unsupportedFile, empty, mapping, invalidInput
    case malformedCSV(Int), missingExpression(Int), language(Int), kind(Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            String(localized: "Use a word list up to 4 MB with at most 10,000 rows.", table: "Vocabulary")
        case .encoding:
            String(localized: "Save the word list as UTF-8 or UTF-16 text and try again.", table: "Vocabulary")
        case .unsupportedFile:
            String(localized: "Choose a CSV or TXT word list.", table: "Vocabulary")
        case .empty:
            String(localized: "The word list has no entries to import.", table: "Vocabulary")
        case .mapping:
            String(localized: "Choose the column containing the expressions.", table: "Vocabulary")
        case .invalidInput:
            String(localized: "Check the expression, meaning, notes, and tags before saving.", table: "Vocabulary")
        case .malformedCSV(let row):
            String(localized: "Check the CSV quoting near line \(row).", table: "Vocabulary")
        case .missingExpression(let row):
            String(localized: "An expression is missing on line \(row).", table: "Vocabulary")
        case .language(let row):
            String(localized: "Use a supported language code on line \(row), such as en or zh-Hans.", table: "Vocabulary")
        case .kind(let row):
            String(localized: "Use word, expression, pattern, or sentence as the type on line \(row).", table: "Vocabulary")
        }
    }
}
