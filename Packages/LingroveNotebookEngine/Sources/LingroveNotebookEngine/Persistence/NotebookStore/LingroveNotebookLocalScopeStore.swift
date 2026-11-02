import Foundation

/// Borrows the caller's SQLite transaction. The durable random token records the
/// local account/workspace lifetime, including a switch away and back (ABA).
/// It is neither a cloud credential nor part of the portable corpus document.
/// Notebook snapshots and wire-window bindings share this one read primitive.
public nonisolated struct LingroveNotebookLocalScopeStore {
    public let core: DatabaseCore

    public func generationInTransaction() throws -> String {
        guard let value = try core.scalarOptionalText(
            sql: "SELECT generation FROM notebook_window_binding WHERE settings_id=1", values: []
        ) else { throw LingroveNotebookWindowStoreError.corruptStage }
        return value
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
