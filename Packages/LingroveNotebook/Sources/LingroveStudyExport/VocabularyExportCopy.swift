import Foundation

/// Both hosts use the export resource bundle. Keeping labels with the portable
/// types lets the mobile sheet reuse the Mac vocabulary without bundle lookups
/// accidentally falling back to another application's similarly named table.
nonisolated public enum VocabularyExportCopy {
    public static var title: String { String(localized: "Export study material", table: "Vocabulary", bundle: .module) }
    public static var scope: String { String(localized: "Scope", table: "Vocabulary", bundle: .module) }
    public static var format: String { String(localized: "Format", table: "Vocabulary", bundle: .module) }
    public static var textStyle: String { String(localized: "Text style", table: "Vocabulary", bundle: .module) }
    public static var spreadsheet: String { String(localized: "Spreadsheet compatibility", table: "Vocabulary", bundle: .module) }
    public static var prepare: String { String(localized: "Prepare", table: "Vocabulary", bundle: .module) }
    public static var preview: String { String(localized: "Preview", table: "Vocabulary", bundle: .module) }
    public static var share: String { String(localized: "Share or Save to Files", table: "Vocabulary", bundle: .module) }
    public static var meanings: String { String(localized: "Meanings", table: "Vocabulary", bundle: .module) }
    public static var examples: String { String(localized: "Example sentence", table: "Vocabulary", bundle: .module) }
    public static var notes: String { String(localized: "Notes", table: "Vocabulary", bundle: .module) }
    public static var explanations: String { String(localized: "Saved explanations", table: "Vocabulary", bundle: .module) }
    public static var content: String { String(localized: "Supplemental content", table: "Vocabulary", bundle: .module) }
    public static var images: String { String(localized: "Image", table: "Vocabulary", bundle: .module) }
    public static var expressions: String { String(localized: "Expressions", table: "Vocabulary", bundle: .module) }
}
