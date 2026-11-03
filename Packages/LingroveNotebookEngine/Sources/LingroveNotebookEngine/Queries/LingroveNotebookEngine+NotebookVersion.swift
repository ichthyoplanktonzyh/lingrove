import Foundation
import LingroveNotebook
import SQLite3

/// A content-free fence for one committed notebook. UI admission and actor caches need only
/// this identity, revision and durable account generation; decoding the corpus to obtain them
/// would put every saved category and translation on the main thread's interaction path.
public nonisolated struct LingroveNotebookVersion: Equatable, Sendable {
    public let workspaceId: String
    public let notebookId: UUID
    public let revision: UInt64
    public let generation: String

    public init(_ snapshot: LingroveNotebookSnapshot) {
        self.init(workspaceId: snapshot.workspaceId, notebookId: snapshot.notebookId,
            revision: snapshot.revision, generation: snapshot.generation)
    }

    init(workspaceId: String, notebookId: UUID, revision: UInt64, generation: String) {
        self.workspaceId = workspaceId; self.notebookId = notebookId
        self.revision = revision; self.generation = generation
    }

    public func hasSameOwner(as other: LingroveNotebookVersion) -> Bool {
        workspaceId == other.workspaceId && notebookId == other.notebookId && generation == other.generation
    }

    public func hasSameOwner(as snapshot: LingroveNotebookSnapshot) -> Bool {
        hasSameOwner(as: Self(snapshot))
    }
}

extension LingroveNotebookEngine {
    /// One deferred read transaction observes active workspace, notebook revision and generation
    /// together without acquiring SQLite's writer lock. nil means the active workspace has not
    /// opened a notebook yet; malformed/missing account state is still an explicit failure.
    public func currentNotebookVersion() throws -> LingroveNotebookVersion? {
        try core.inReadTransaction {
            let values = try core.query(sql: """
                SELECT s.active_workspace_id,n.notebook_id,n.revision,b.generation
                FROM app_local_settings s
                LEFT JOIN notebook_state n ON n.workspace_id=s.active_workspace_id
                LEFT JOIN notebook_window_binding b ON b.settings_id=s.settings_id
                WHERE s.settings_id=1
                """, values: []) { statement -> LingroveNotebookVersion? in
                guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                      sqlite3_column_type(statement, 3) == SQLITE_TEXT else { throw VocabularyError.editConflict }
                let workspace = DatabaseCore.columnText(statement: statement, index: 0)
                let generation = DatabaseCore.columnText(statement: statement, index: 3)
                guard !workspace.isEmpty, !generation.isEmpty else { throw VocabularyError.invalidArchive }
                if sqlite3_column_type(statement, 1) == SQLITE_NULL {
                    guard sqlite3_column_type(statement, 2) == SQLITE_NULL else { throw VocabularyError.invalidArchive }
                    return nil
                }
                guard let notebook = UUID(uuidString: DatabaseCore.columnText(statement: statement, index: 1)),
                      sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                      sqlite3_column_int64(statement, 2) >= 0 else { throw VocabularyError.invalidArchive }
                return .init(workspaceId: workspace, notebookId: notebook,
                    revision: UInt64(sqlite3_column_int64(statement, 2)), generation: generation)
            }
            guard let value = values.first else { throw VocabularyError.editConflict }
            return value
        }
    }
}
