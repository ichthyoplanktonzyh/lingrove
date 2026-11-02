import CryptoKit
import Foundation
import LingroveNotebookSync

/// The app presents a snapshot of a durable conflict, not a writable document.
/// Choices identify public fields/entities; private Anki state stays in its
/// existing document/remainder and is never part of the network request.
public nonisolated struct LingroveNotebookConflictSession: Identifiable, Sendable {
    public let id: String
    public let binding: LingroveNotebookWindowBinding
    public let localRevision: UInt64
    public let candidates: [VocabularyWireConflictSelection]
    public let authorized: Bool

    public init(id: String, binding: LingroveNotebookWindowBinding, localRevision: UInt64, candidates: [VocabularyWireConflictSelection], authorized: Bool) {
        self.id = id
        self.binding = binding
        self.localRevision = localRevision
        self.candidates = candidates
        self.authorized = authorized
    }
}

/// LocalDatabase owns this adapter. A conflict survives process death, ordinary
/// retry and account switches. Only a CAS-checked explicit choice authorizes a
/// later rebase; that rebase still validates every value and the complete graph.
public nonisolated struct LingroveNotebookConflictStore {
    public let core: DatabaseCore

    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_sync_conflicts (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            conflict_id TEXT NOT NULL,
            owner_user_id TEXT NOT NULL,
            remote_notebook_id TEXT NOT NULL,
            replica_id TEXT NOT NULL,
            local_revision INTEGER NOT NULL CHECK(local_revision>=0),
            candidates_json TEXT NOT NULL,
            candidates_sha256 TEXT NOT NULL CHECK(length(candidates_sha256)=64),
            selections_json TEXT,
            authorized_generation TEXT,
            CHECK((selections_json IS NULL)=(authorized_generation IS NULL))
        );
        CREATE TABLE IF NOT EXISTS notebook_sync_rejections (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            group_id TEXT NOT NULL,
            public_revision INTEGER NOT NULL CHECK(public_revision>=0),
            authorized_generation TEXT
        );
        """
    public static let resetSQL = "DROP TABLE IF EXISTS notebook_sync_rejections;\nDROP TABLE IF EXISTS notebook_sync_conflicts;"

    public func load(binding: LingroveNotebookWindowBinding) throws -> LingroveNotebookConflictSession? {
        try core.inReadTransaction { try loadInTransaction(binding: binding) }
    }

    public func loadInTransaction(binding: LingroveNotebookWindowBinding) throws -> LingroveNotebookConflictSession? {
        try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
        return try core.query(sql: """
            SELECT conflict_id,owner_user_id,remote_notebook_id,replica_id,local_revision,candidates_json,candidates_sha256,authorized_generation
            FROM notebook_sync_conflicts WHERE workspace_id=?
            """, values: [.text(workspace(binding))]) { row in
            guard DatabaseCore.columnText(statement: row, index: 1).utf8.elementsEqual(binding.scope.ownerUserID.utf8),
                  UUID(uuidString: DatabaseCore.columnText(statement: row, index: 2)) == binding.scope.notebookID,
                  UUID(uuidString: DatabaseCore.columnText(statement: row, index: 3)) == binding.scope.replicaID else {
                throw LingroveNotebookSyncStoreError.scopeChanged
            }
            let json = DatabaseCore.columnText(statement: row, index: 5)
            guard digest(json) == DatabaseCore.columnText(statement: row, index: 6) else { throw LingroveNotebookSyncStoreError.corruptState }
            let candidates = try JSONDecoder().decode([VocabularyWireConflictSelection].self, from: Data(json.utf8))
            let revision = DatabaseCore.columnInt64(statement: row, index: 4)
            guard revision >= 0, !candidates.isEmpty else { throw LingroveNotebookSyncStoreError.corruptState }
            return LingroveNotebookConflictSession(id: DatabaseCore.columnText(statement: row, index: 0), binding: binding,
                localRevision: UInt64(revision), candidates: candidates,
                authorized: DatabaseCore.columnOptionalText(statement: row, index: 7) == binding.generation)
        }.first
    }

    public func selectionsInTransaction(binding: LingroveNotebookWindowBinding) throws -> [VocabularyWireConflictSelection] {
        guard let session = try loadInTransaction(binding: binding), session.authorized,
              let json = try core.scalarOptionalText(sql: "SELECT selections_json FROM notebook_sync_conflicts WHERE workspace_id=?",
                values: [.text(workspace(binding))]) else { return [] }
        return try JSONDecoder().decode([VocabularyWireConflictSelection].self, from: Data(json.utf8))
    }
    /// Includes local authorization metadata in apply's CAS fence. A choice
    /// changed while preparation runs cannot be silently replaced by that old
    /// prepared candidate, even when the document revision is unchanged.
    public func resolutionTokenInTransaction(binding: LingroveNotebookWindowBinding) throws -> String {
        let conflict = try core.query(sql: "SELECT conflict_id,candidates_sha256,COALESCE(selections_json,''),COALESCE(authorized_generation,'') FROM notebook_sync_conflicts WHERE workspace_id=?",
            values: [.text(workspace(binding))]) { row in (0...3).map { DatabaseCore.columnText(statement: row, index: Int32($0)) } }.flatMap { $0 }
        let adoption = try core.query(sql: "SELECT recovery_id,decision,COALESCE(authorized_generation,''),CAST(completed AS TEXT) FROM notebook_first_connections WHERE workspace_id=?",
            values: [.text(workspace(binding))]) { row in (0...3).map { DatabaseCore.columnText(statement: row, index: Int32($0)) } }.flatMap { $0 }
        return digest(String(decoding: try JSONEncoder().encode(conflict + adoption), as: UTF8.self))
    }

    /// Called only after re-reading the document/shadow/pending identity under
    /// the writer lock. A failed apply never changes any of those three values.
    public func recordInTransaction(_ candidates: [VocabularyWireConflictSelection], local: LingroveNotebookSnapshot,
                             binding: LingroveNotebookWindowBinding) throws {
        try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
        let json = try encode(candidates)
        let sha = digest(json)
        let old = try loadInTransaction(binding: binding)
        if old?.localRevision == local.revision,
           try core.scalarOptionalText(sql: "SELECT candidates_sha256 FROM notebook_sync_conflicts WHERE workspace_id=?",
                values: [.text(workspace(binding))]) == sha { return }
        try core.execute(sql: """
            INSERT INTO notebook_sync_conflicts(workspace_id,conflict_id,owner_user_id,remote_notebook_id,replica_id,local_revision,candidates_json,candidates_sha256)
            VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(workspace_id) DO UPDATE SET
              conflict_id=excluded.conflict_id,local_revision=excluded.local_revision,candidates_json=excluded.candidates_json,
              candidates_sha256=excluded.candidates_sha256,selections_json=NULL,authorized_generation=NULL
            """, values: [.text(workspace(binding)), .text(UUID().uuidString.lowercased()), .text(binding.scope.ownerUserID),
                .text(binding.scope.notebookID.uuidString.lowercased()), .text(binding.scope.replicaID.uuidString.lowercased()),
                .integer(Int64(local.revision)), .text(json), .text(sha)])
    }

    public func authorize(_ session: LingroveNotebookConflictSession, choices: [Int: VocabularyWireConflictSelection.Choice]) throws {
        try core.inTransaction {
            let binding = session.binding
            guard let current = try loadInTransaction(binding: binding), current.id == session.id,
                  current.localRevision == session.localRevision, choices.count == current.candidates.count,
                  try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspace(binding)).revision == session.localRevision else {
                throw LingroveNotebookSyncStoreError.stalePreparation
            }
            let selections = try current.candidates.enumerated().map { index, candidate in
                guard let choice = choices[index], !(candidate.conflict.reason == .retiredIdentity && choice == .local),
                      !(candidate.remote == nil && candidate.remoteVersion != nil && choice == .local) else {
                    throw VocabularyWireRebaseError.staleResolution
                }
                return VocabularyWireConflictSelection(conflict: candidate.conflict, local: candidate.local, remote: candidate.remote,
                    remoteVersion: candidate.remoteVersion, choice: choice)
            }
            try core.execute(sql: "UPDATE notebook_sync_conflicts SET selections_json=?,authorized_generation=? WHERE workspace_id=? AND conflict_id=?",
                values: [.text(try encode(selections)), .text(binding.generation), .text(workspace(binding)), .text(session.id)])
        }
    }

    public func clearInTransaction(binding: LingroveNotebookWindowBinding) throws {
        try core.execute(sql: "DELETE FROM notebook_sync_conflicts WHERE workspace_id=?", values: [.text(workspace(binding))])
    }
    public func recordRejectionInTransaction(_ rejection: VocabularyWireGroupRejection, binding: LingroveNotebookWindowBinding) throws {
        guard rejection.reason == .invalidCorpus else { return }
        try core.execute(sql: """
            INSERT INTO notebook_sync_rejections(workspace_id,group_id,public_revision)
            VALUES(?,?,(SELECT COALESCE(MAX(revision),0) FROM notebook_pending_transactions WHERE workspace_id=? AND has_public_change=1))
            ON CONFLICT(workspace_id) DO UPDATE SET group_id=excluded.group_id,public_revision=excluded.public_revision,authorized_generation=NULL
            """, values: [.text(workspace(binding)), .text(rejection.groupID.uuidString.lowercased()), .text(workspace(binding))])
    }
    public func checkRejectionInTransaction(binding: LingroveNotebookWindowBinding) throws {
        let blocked = try core.scalarInt(sql: """
            SELECT COUNT(*) FROM notebook_sync_rejections r WHERE r.workspace_id=? AND r.authorized_generation IS NOT ?
            AND r.public_revision >= (SELECT COALESCE(MAX(revision),0) FROM notebook_pending_transactions WHERE workspace_id=r.workspace_id AND has_public_change=1)
            """, values: [.text(workspace(binding)), .text(binding.generation)])
        if blocked != 0 { throw LingroveNotebookUploadStoreError.rejectedIntent }
    }
    public func clearRejectionInTransaction(binding: LingroveNotebookWindowBinding) throws {
        try core.execute(sql: "DELETE FROM notebook_sync_rejections WHERE workspace_id=?", values: [.text(workspace(binding))])
    }
    private func workspace(_ binding: LingroveNotebookWindowBinding) -> String { binding.scope.workspaceID.uuidString.lowercased() }
    private func encode(_ selections: [VocabularyWireConflictSelection]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(selections), as: UTF8.self)
    }
    private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
