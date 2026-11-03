import Foundation

/// Wording for the outer notebook navigation lives in its own catalog. Account and sync
/// descriptions still come from their existing safe presentation maps; no service error or
/// private identity is converted into a new sidebar string here.
enum NotebookWorkspaceCopy {
    static func text(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), table: "NotebookWorkspace")
    }

    static func title(_ destination: NotebookWorkspaceDestination) -> String {
        text("nav." + destination.rawValue)
    }

    static func symbol(_ destination: NotebookWorkspaceDestination) -> String {
        switch destination {
        case .corpus: "books.vertical"
        case .review: "rectangle.on.rectangle"
        case .progress: "chart.bar.xaxis"
        }
    }
}
