import Foundation
import LingroveNotebook

/// The app facade uses its existing database lifetime for notebook operations. Values passed
/// across the UI boundary carry a scope/revision; all SQLite work stays in the store transaction.
extension LingroveNotebookEngine {
    public func hasCommittedLingroveNotebook() throws -> Bool {
        try self.lingroveNotebookStore.hasCommittedNotebook()
    }

    /// Account paths now retain notebook-bearing workspaces and present an
    /// explicit ownership handoff. Destructive Card-only helpers still carry
    /// their own guards; this admission only verifies the database lifetime.
    public func requireLingroveNotebookAccountMigrationSupport() throws {
        _ = try self.hasCommittedLingroveNotebook()
    }

    public func loadLingroveNotebook(workspaceId: String, requireActiveWorkspace: Bool = false) throws -> LingroveNotebookSnapshot {
        try self.lingroveNotebookStore.load(workspaceId: workspaceId, requireActiveWorkspace: requireActiveWorkspace)
    }

    /// Explicit version/token checks make receipt lookup independent of call ordering. A new
    /// connection, external mutation or missing/gapped receipt returns nil; callers then reload.
    public func committedNotebookChange(for version: LingroveNotebookVersion) throws -> LingroveNotebookCommittedChange? {
        try core.inReadTransaction {
            guard let cached = core.notebookSaveCache,
                  LingroveNotebookVersion(cached.snapshot) == version,
                  try currentNotebookVersionInTransaction() == version,
                  try core.notebookCacheToken() == cached.token else { return nil }
            return cached.committedChange
        }
    }

    /// A read-only projection of the already checked connection state. Header, generation and
    /// SQL-clock checks bind these joined values to the caller's exact snapshot; a missing or
    /// externally invalidated cache returns nil rather than inventing a second read authority.
    public func cachedNotebookEntries(for version: LingroveNotebookVersion) throws -> [VocabularyEntry]? {
        try core.inReadTransaction {
            guard let cached = core.notebookSaveCache,
                  LingroveNotebookVersion(cached.snapshot) == version,
                  try currentNotebookVersionInTransaction() == version,
                  try core.notebookCacheToken() == cached.token else { return nil }
            return cached.state.entries
        }
    }

    public func saveLingroveNotebook(
        _ document: VocabularyDocument, basedOn baseline: LingroveNotebookSnapshot,
        restoringBackup: Bool = false, images: [String: Data] = [:], requireActiveWorkspace: Bool = false,
        operationId: String = UUID().uuidString.lowercased()
    ) throws -> LingroveNotebookSnapshot {
        try self.lingroveNotebookStore.save(document, basedOn: baseline, restoringBackup: restoringBackup, images: images,
            requireActiveWorkspace: requireActiveWorkspace, operationId: operationId)
    }
}
