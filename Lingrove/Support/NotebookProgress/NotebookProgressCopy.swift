import Foundation
import LingroveNotebookEngine

/// Progress owns a catalog independent of mobile cloud/community copy and of the corpus page.
/// The same fifteen Mac interface locales resolve these strings through ordinary bundle lookup.
nonisolated enum NotebookProgressCopy {
    static func text(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), table: "NotebookProgress")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: arguments)
    }

    static func rating(_ rating: ReviewRating) -> String {
        switch rating {
        case .again: text("rating.again")
        case .hard: text("rating.hard")
        case .good: text("rating.good")
        case .easy: text("rating.easy")
        }
    }
}
