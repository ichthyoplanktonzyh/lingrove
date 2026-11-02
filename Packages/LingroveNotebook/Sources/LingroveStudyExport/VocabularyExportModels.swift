import LingroveNotebook
import Foundation

/// Export configuration belongs to one sheet, independently of notebook editing and Anki.
/// These values cross to the archive actor; changing a control creates a new prepared payload.
nonisolated public enum VocabularyExportFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
    case text, csv, json
    public var id: String { rawValue }
    public var label: String { self == .text ? "TXT" : rawValue.uppercased() }
    public var fileExtension: String { self == .text ? "txt" : rawValue }
}

nonisolated public enum VocabularyExportTextStyle: String, CaseIterable, Identifiable, Hashable, Sendable {
    case expressions, notes
    public var id: String { rawValue }
    public var label: String {
        self == .expressions ? String(localized: "Expression list", table: "Vocabulary", bundle: .module)
            : String(localized: "Learning notes", table: "Vocabulary", bundle: .module)
    }
}

nonisolated public enum VocabularyExportScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, filtered, selected
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: String(localized: "Entire notebook", table: "Vocabulary", bundle: .module)
        case .filtered: String(localized: "Current results", table: "Vocabulary", bundle: .module)
        case .selected: String(localized: "Selected senses", table: "Vocabulary", bundle: .module)
        }
    }
}

/// Scope IDs capture what the window offered when Export was opened. Exact IDs prevent a
/// concurrent merge from silently broadening a selected meaning to include another meaning.
nonisolated public struct VocabularyExportRequest: Identifiable, Sendable {
    public let id = UUID()
    public let all: [VocabularySelection]
    public let filtered: [VocabularySelection]
    public let selected: [VocabularySelection]
    public let initialScope: VocabularyExportScope

    public init(all: [VocabularySelection], filtered: [VocabularySelection], selected: [VocabularySelection], initialScope: VocabularyExportScope) {
        self.all = all; self.filtered = filtered; self.selected = selected; self.initialScope = initialScope
    }

    public func selections(_ scope: VocabularyExportScope) -> [VocabularySelection] {
        switch scope {
        case .all: all
        case .filtered: filtered
        case .selected: selected
        }
    }
}

nonisolated public struct VocabularyExportConfiguration: Hashable, Sendable {
    public init(format: VocabularyExportFormat = .text, textStyle: VocabularyExportTextStyle = .notes,
                meanings: Bool = true, examples: Bool = true, notes: Bool = true, explanation: Bool = false,
                content: Bool = true, images: Bool = false, spreadsheetCompatibility: Bool = true) {
        self.format = format; self.textStyle = textStyle; self.meanings = meanings; self.examples = examples
        self.notes = notes; self.explanation = explanation; self.content = content; self.images = images
        self.spreadsheetCompatibility = spreadsheetCompatibility
    }
    public var format: VocabularyExportFormat = .text
    public var textStyle: VocabularyExportTextStyle = .notes
    public var meanings = true
    public var examples = true
    public var notes = true
    public var explanation = false
    public var content = true
    public var images = false
    public var spreadsheetCompatibility = true
    public var isExpressionList: Bool { format == .text && textStyle == .expressions }
    public var includesImages: Bool { !isExpressionList && content && images }
}

/// A prepared package is immutable and owns the exact media bytes named by its metadata.
/// The sheet retains it until controls change or it closes; writing never re-reads live content.
nonisolated public struct VocabularyExportPackage: Sendable {
    public let id = UUID()
    public let configuration: VocabularyExportConfiguration
    public let data: Data
    public let preview: String
    public let entryCount: Int
    public let senseCount: Int
    public let exampleCount: Int
    public init(configuration: VocabularyExportConfiguration, data: Data, preview: String,
                entryCount: Int, senseCount: Int, exampleCount: Int, images: [String: Data] = [:]) {
        self.configuration = configuration; self.data = data; self.preview = preview
        self.entryCount = entryCount; self.senseCount = senseCount; self.exampleCount = exampleCount; self.images = images
    }
    public var images: [String: Data] = [:]
    public var dataFilename: String { "Lingrove-vocabulary." + configuration.format.fileExtension }
    public var filename: String { configuration.includesImages ? "Lingrove-vocabulary.zip" : dataFilename }
}

/// Portable JSON has its own versioned shape. It includes selected learning material rather
/// than runtime settings, host app identifiers or remote review receipts from a full backup.
nonisolated public struct VocabularyExportDocument: Codable, Sendable {
    public var format = "lingrove-vocabulary-export"
    public var version = 1
    public let entries: [Entry]
    public var semantics: VocabularySemanticIndex?
    public var classification: VocabularyClassificationIndex?

    public struct Entry: Codable, Sendable {
        public let id: UUID
        public let expression: String
        public let dictionaryForm: String
        public let language: LearningLanguage?
        public let kind: VocabularyEntry.Kind
        public let senses: [Sense]
    }
    public struct Sense: Codable, Sendable {
        public let id: UUID
        public let createdAt: Date
        public let meaning: String?
        public let meaningLanguage: LearningLanguage?
        public let otherMeanings: [VocabularyMeaning]?
        public let note: String?
        public let tags: [String]?
        public let examples: [Usage]?
        public let explanations: [Explanation]?
        public let content: [Block]?
    }
    public struct Usage: Codable, Sendable {
        public let id: UUID
        public let createdAt: Date
        public let text: String
        public let completeness: VocabularyExample.Completeness
        public let ranges: [VocabularyTextRange]
        public let translation: String
        public let translationLanguage: LearningLanguage?
        public let otherTranslations: [VocabularyMeaning]
        public let meaning: String?
        public let meaningLanguage: LearningLanguage?
        public let explanations: [Explanation]?
    }
    public struct Explanation: Codable, Sendable {
        public let language: LearningLanguage
        public let meaning: String
        public let detail: String
    }
    public struct Block: Codable, Sendable {
        public let id: UUID
        public let text: VocabularyTextContent?
        public let image: VocabularyImageReference?
        public let filename: String?
        public let caption: String?
    }
}

nonisolated public enum VocabularyExportError: LocalizedError, Equatable {
    case empty, changed, missingImage, tooLarge
    public var errorDescription: String? {
        switch self {
        case .empty: String(localized: "Choose at least one sense to export.", table: "Vocabulary", bundle: .module)
        case .changed: String(localized: "The selected senses changed. Reopen Export to refresh the selection.", table: "Vocabulary", bundle: .module)
        case .missingImage: String(localized: "An export image is missing. Restore it or export without images.", table: "Vocabulary", bundle: .module)
        case .tooLarge: String(localized: "This export is too large. Export a smaller selection.", table: "Vocabulary", bundle: .module)
        }
    }
}
