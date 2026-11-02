import Foundation
import LingroveNotebook
import LingroveNotebookStorage

/// An offline file operation binds to the same durable local ABA token as sync,
/// without requiring cloud membership. The original database captures it before
/// dispatch; each connection rechecks it before exposing a prepared file.
public nonisolated struct LingroveNotebookBackupBinding: Equatable, Sendable {
    public let workspaceId: String
    public let notebookId: UUID
    public let revision: UInt64
    public let generation: String

    public init(workspaceId: String, notebookId: UUID, revision: UInt64, generation: String) {
        self.workspaceId = workspaceId
        self.notebookId = notebookId
        self.revision = revision
        self.generation = generation
    }
}

/// Borrows one Core. Metadata admission is cheap enough for the original UI
/// connection; full graph and PNG reads belong to the IO worker's read transaction.
/// Export never creates a notebook, advances its revision or writes an outbox.
public nonisolated struct LingroveNotebookBackupStore {
    public let core: DatabaseCore

    public func capture(_ expected: LingroveNotebookSnapshot) throws -> LingroveNotebookBackupBinding {
        try core.inReadTransaction {
            let binding = LingroveNotebookBackupBinding(workspaceId: expected.workspaceId, notebookId: expected.notebookId,
                revision: expected.revision, generation: expected.generation)
            try checkInTransaction(binding)
            return binding
        }
    }

    public func check(_ binding: LingroveNotebookBackupBinding) throws {
        try core.inReadTransaction { try checkInTransaction(binding) }
    }

    public func read(_ binding: LingroveNotebookBackupBinding) throws -> VocabularyBackup {
        try core.inReadTransaction {
            try checkInTransaction(binding)
            let snapshot = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: binding.workspaceId)
            guard snapshot.notebookId == binding.notebookId, snapshot.revision == binding.revision else {
                throw VocabularyError.editConflict
            }
            let references = Set(VocabularyDocumentValidation.imageReferences(snapshot.document))
            guard references.reduce(0, { $0 + $1.byteCount }) <= VocabularyDocumentValidation.maximumMediaBytes else {
                throw VocabularyError.oversizedArchive
            }
            let media = LingroveNotebookMediaStore(core: core)
            var images: [String: Data] = [:]
            for reference in references.sorted(by: { $0.filename < $1.filename }) {
                try Task.checkCancellation()
                images[reference.filename] = try media.imageInTransaction(reference, scope: snapshot, requireActiveWorkspace: true)
            }
            try checkInTransaction(binding)
            return VocabularyBackup(document: snapshot.document, images: images)
        }
    }

    // Study exports borrow this same admission inside their document/media read
    // transaction. They must not open a nested SQLite BEGIN or mint a new token.
    public func checkInTransaction(_ binding: LingroveNotebookBackupBinding) throws {
        guard binding.revision <= UInt64(Int64.max),
              try LingroveNotebookLocalScopeStore(core: core).generationInTransaction() == binding.generation,
              try core.scalarInt(sql: """
                SELECT count(*) FROM notebook_state n JOIN app_local_settings a ON a.settings_id=1
                WHERE n.workspace_id=? AND n.notebook_id=? AND n.revision=? AND a.active_workspace_id=n.workspace_id
                """, values: [.text(binding.workspaceId), .text(binding.notebookId.uuidString), .integer(Int64(binding.revision))]) == 1 else {
            throw VocabularyError.editConflict
        }
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
