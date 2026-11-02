import Foundation

/// Notebook-specific lifecycle failures remain distinct from SQLite and transport errors, so a
/// pending account migration can explain how to preserve local content instead of discarding it.
public nonisolated enum LingroveNotebookError: LocalizedError {
    case workspaceMigrationPending

    public var errorDescription: String? {
        String(localized: "notebook.workspace_migration_pending",
            defaultValue: "This workspace contains a local notebook. Keep this workspace until notebook account migration is available. Your notebook has been preserved.",
            table: "Notebook", comment: "Local notebook blocks destructive account workspace replacement until notebook sync supports migration")
    }
}
