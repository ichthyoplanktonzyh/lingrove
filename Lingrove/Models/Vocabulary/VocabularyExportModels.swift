import Foundation

/// Export configuration belongs to one sheet, independently of notebook editing and Anki.
/// These values cross to the archive actor; changing a control creates a new prepared payload.
nonisolated enum VocabularyExportFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
    case text, csv, json
    var id: String { rawValue }
    var label: String { self == .text ? "TXT" : rawValue.uppercased() }
    var fileExtension: String { self == .text ? "txt" : rawValue }
}

nonisolated enum VocabularyExportTextStyle: String, CaseIterable, Identifiable, Hashable, Sendable {
    case expressions, notes
    var id: String { rawValue }
    var label: String {
        self == .expressions ? String(localized: "Expression list", table: "Vocabulary")
            : String(localized: "Learning notes", table: "Vocabulary")
    }
}

nonisolated enum VocabularyExportScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, filtered, selected
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: String(localized: "Entire notebook", table: "Vocabulary")
        case .filtered: String(localized: "Current results", table: "Vocabulary")
        case .selected: String(localized: "Selected senses", table: "Vocabulary")
        }
    }
}

/// Scope IDs capture what the window offered when Export was opened. Exact IDs prevent a
/// concurrent merge from silently broadening a selected meaning to include another meaning.
nonisolated struct VocabularyExportRequest: Identifiable, Sendable {
    let id = UUID()
    let all: [VocabularySelection]
    let filtered: [VocabularySelection]
    let selected: [VocabularySelection]
    let initialScope: VocabularyExportScope

    func selections(_ scope: VocabularyExportScope) -> [VocabularySelection] {
        switch scope {
        case .all: all
        case .filtered: filtered
        case .selected: selected
        }
    }
}

nonisolated struct VocabularyExportConfiguration: Hashable, Sendable {
    var format: VocabularyExportFormat = .text
    var textStyle: VocabularyExportTextStyle = .notes
    var meanings = true
    var examples = true
    var notes = true
    var explanation = false
    var content = true
    var images = false
    var spreadsheetCompatibility = true
    var isExpressionList: Bool { format == .text && textStyle == .expressions }
    var includesImages: Bool { !isExpressionList && content && images }
}

/// A prepared package is immutable and owns the exact media bytes named by its metadata.
/// The sheet retains it until controls change or it closes; writing never re-reads live content.
nonisolated struct VocabularyExportPackage: Sendable {
    let id = UUID()
    let configuration: VocabularyExportConfiguration
    let data: Data
    let preview: String
    let entryCount: Int
    let senseCount: Int
    let exampleCount: Int
    var images: [String: Data] = [:]
    var dataFilename: String { "Lingrove-vocabulary." + configuration.format.fileExtension }
    var filename: String { configuration.includesImages ? "Lingrove-vocabulary.zip" : dataFilename }
}

/// Portable JSON has its own versioned shape. It includes selected learning material rather
/// than runtime settings, host app identifiers or remote review receipts from a full backup.
nonisolated struct VocabularyExportDocument: Codable, Sendable {
    var format = "lingrove-vocabulary-export"
    var version = 1
    let entries: [Entry]
    var semantics: VocabularySemanticIndex?

    struct Entry: Codable, Sendable {
        let id: UUID
        let expression: String
        let dictionaryForm: String
        let language: LearningLanguage?
        let kind: VocabularyEntry.Kind
        let senses: [Sense]
    }
    struct Sense: Codable, Sendable {
        let id: UUID
        let createdAt: Date
        let meaning: String?
        let meaningLanguage: LearningLanguage?
        let otherMeanings: [VocabularyMeaning]?
        let note: String?
        let tags: [String]?
        let examples: [Usage]?
        let explanations: [Explanation]?
        let content: [Block]?
    }
    struct Usage: Codable, Sendable {
        let id: UUID
        let createdAt: Date
        let text: String
        let completeness: VocabularyExample.Completeness
        let ranges: [VocabularyTextRange]
        let translation: String
        let translationLanguage: LearningLanguage?
        let otherTranslations: [VocabularyMeaning]
        let meaning: String?
        let meaningLanguage: LearningLanguage?
        let explanations: [Explanation]?
    }
    struct Explanation: Codable, Sendable {
        let language: LearningLanguage
        let meaning: String
        let detail: String
    }
    struct Block: Codable, Sendable {
        let id: UUID
        let text: VocabularyTextContent?
        let image: VocabularyImageReference?
        let filename: String?
        let caption: String?
    }
}

nonisolated enum VocabularyExportError: LocalizedError {
    case empty, changed, missingImage, tooLarge
    var errorDescription: String? {
        switch self {
        case .empty: String(localized: "Choose at least one sense to export.", table: "Vocabulary")
        case .changed: String(localized: "The selected senses changed. Reopen Export to refresh the selection.", table: "Vocabulary")
        case .missingImage: String(localized: "An export image is missing. Restore it or export without images.", table: "Vocabulary")
        case .tooLarge: String(localized: "This export is too large. Export a smaller selection.", table: "Vocabulary")
        }
    }
}
