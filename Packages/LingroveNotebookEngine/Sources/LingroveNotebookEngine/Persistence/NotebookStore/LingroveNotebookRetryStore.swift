import Foundation
import LingroveNotebookSync
import SQLite3

/// A click captures only already-existing cancellations. It cannot authorize a
/// newer Cancel, another frozen group, or an account that reused the same IDs.
public nonisolated struct LingroveNotebookRetryAuthorization: Sendable {
    public struct Pending: Sendable {
        public let groupID: UUID
        public let frozenSHA256: String
        public let cancelRevision: Int64

        public init(groupID: UUID, frozenSHA256: String, cancelRevision: Int64) {
            self.groupID = groupID
            self.frozenSHA256 = frozenSHA256
            self.cancelRevision = cancelRevision
        }
}
    public let binding: LingroveNotebookWindowBinding
    public let completedGroups: [UUID]
    public let pending: Pending?
    public let rejectionID: String?
    public init(binding: LingroveNotebookWindowBinding, completedGroups: [UUID], pending: Pending?, rejectionID: String? = nil) {
        self.binding = binding; self.completedGroups = completedGroups; self.pending = pending; self.rejectionID = rejectionID
    }
}
public nonisolated struct LingroveNotebookRetryState: Equatable, Sendable {
    public let cancelRevision: Int64
    public let resumeRevision: Int64?
    public var isResumed: Bool { cancelRevision > 0 && resumeRevision == cancelRevision }

    public init(cancelRevision: Int64, resumeRevision: Int64?) {
        self.cancelRevision = cancelRevision
        self.resumeRevision = resumeRevision
    }
}

/// Borrows the local connection; owns no corpus or networking. Versioned local
/// cancellation intent survives an offline retry, while each new Cancel revokes
/// earlier authorization. Completed closure ledgers preserve the revision so a
/// delayed retry can settle the exact old group after its body was retired.
public struct LingroveNotebookRetryStore {
    public let core: DatabaseCore
    public func initializeInTransaction(upload: VocabularyWireStagedUpload, frozenSHA256: String) throws {
        try core.execute(sql: "INSERT INTO notebook_upload_retry_intents(workspace_id,frozen_sha256,group_id,cancel_revision) VALUES(?,?,?,0)",
            values: [.text(upload.batch.scope.workspaceID.uuidString.lowercased()), .text(frozenSHA256), .text(upload.batch.request.groupID.uuidString.lowercased())])
    }
    public func readInTransaction(upload: VocabularyWireStagedUpload, frozenSHA256: String, cancelRequested: Bool) throws -> LingroveNotebookRetryState {
        let rows = try core.query(sql: "SELECT frozen_sha256,group_id,cancel_revision,resume_revision FROM notebook_upload_retry_intents WHERE workspace_id=?",
            values: [.text(upload.batch.scope.workspaceID.uuidString.lowercased())]) { statement in
            guard try text(statement, 0) == frozenSHA256, UUID(uuidString: try text(statement, 1)) == upload.batch.request.groupID else {
                throw LingroveNotebookUploadStoreError.corruptBatch
            }
            return try state(statement, cancelIndex: 2, resumeIndex: 3, cancelRequested: cancelRequested)
        }
        guard rows.count == 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return rows[0]
    }
    public func cancelInTransaction(_ pending: LingroveNotebookPendingUpload) throws {
        guard pending.batch.transport == .staged else { return }
        guard try core.execute(sql: """
            UPDATE notebook_upload_retry_intents SET cancel_revision=cancel_revision+1,resume_revision=NULL
            WHERE workspace_id=? AND frozen_sha256=? AND cancel_revision<?
            """, values: [.text(pending.batch.scope.workspaceID.uuidString.lowercased()), .text(pending.frozenSHA256), .integer(Int64.max)]) == 1 else {
            throw LingroveNotebookUploadStoreError.corruptBatch
        }
    }
    public func captureKnown(_ ticket: LingroveNotebookWindowBinding) throws -> LingroveNotebookRetryAuthorization? {
        try core.inReadTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(ticket)
            let rows = try core.query(sql: """
                SELECT r.owner_user_id,r.remote_notebook_id,r.replica_id,r.local_notebook_id,n.notebook_id
                FROM notebook_remote_state r JOIN notebook_state n USING(workspace_id) WHERE r.workspace_id=?
                """, values: [.text(workspace(ticket))]) { statement in
                let owner = try text(statement, 0)
                guard owner.utf8.elementsEqual(ticket.scope.ownerUserID.utf8), let book = UUID(uuidString: try text(statement, 1)),
                      let replica = UUID(uuidString: try text(statement, 2)), let local = UUID(uuidString: try text(statement, 3)),
                      local == UUID(uuidString: try text(statement, 4)) else { throw LingroveNotebookSyncStoreError.scopeChanged }
                return LingroveNotebookWindowBinding(scope: .init(ownerUserID: owner, workspaceID: ticket.scope.workspaceID, notebookID: book, replicaID: replica), generation: ticket.generation)
            }
            guard let binding = rows.first else { return nil }
            let groups = try core.query(sql: "SELECT group_id FROM notebook_completed_upload_closures WHERE workspace_id=? AND retry_blocked=1 ORDER BY group_id",
                values: [.text(workspace(binding))]) { statement in
                guard let id = UUID(uuidString: try text(statement, 0)) else { throw LingroveNotebookUploadStoreError.corruptBatch }
                return id
            }
            let pending = try core.query(sql: """
                SELECT u.frozen_sha256,i.frozen_sha256,i.group_id,i.cancel_revision,i.resume_revision,t.cancel_requested,t.frozen_sha256,
                  u.owner_user_id,u.remote_notebook_id,u.replica_id
                FROM notebook_upload_batches u LEFT JOIN notebook_upload_retry_intents i USING(workspace_id)
                LEFT JOIN notebook_upload_terminal_state t USING(workspace_id)
                WHERE u.workspace_id=? AND u.transport_kind='staged'
                """, values: [.text(workspace(binding))]) { statement -> LingroveNotebookRetryAuthorization.Pending? in
                let frozen = try text(statement, 0)
                guard try text(statement, 1) == frozen, try text(statement, 6) == frozen,
                      let group = UUID(uuidString: try text(statement, 2)), sqlite3_column_type(statement, 5) == SQLITE_INTEGER,
                      [0,1].contains(sqlite3_column_int64(statement, 5)),
                      (try text(statement, 7)).utf8.elementsEqual(binding.scope.ownerUserID.utf8),
                      UUID(uuidString: try text(statement, 8)) == binding.scope.notebookID,
                      UUID(uuidString: try text(statement, 9)) == binding.scope.replicaID else { throw LingroveNotebookUploadStoreError.corruptBatch }
                let value = try state(statement, cancelIndex: 3, resumeIndex: 4, cancelRequested: sqlite3_column_int64(statement, 5) == 1)
                return value.cancelRevision > 0 ? .init(groupID: group, frozenSHA256: frozen, cancelRevision: value.cancelRevision) : nil
            }.first ?? nil
            let rejection = try core.query(sql: "SELECT group_id FROM notebook_sync_rejections WHERE workspace_id=?", values: [.text(workspace(binding))]) {
                DatabaseCore.columnText(statement: $0, index: 0)
            }.first
            return .init(binding: binding, completedGroups: groups, pending: pending, rejectionID: rejection)
        }
    }
    public func authorize(_ authorization: LingroveNotebookRetryAuthorization) throws {
        try core.inTransaction {
            let binding = authorization.binding
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            guard try core.scalarInt(sql: """
                SELECT count(*) FROM notebook_remote_state r JOIN notebook_state n USING(workspace_id)
                WHERE r.workspace_id=? AND r.owner_user_id=? COLLATE BINARY AND r.remote_notebook_id=? AND r.replica_id=?
                  AND lower(r.local_notebook_id)=lower(n.notebook_id)
                """, values: [.text(workspace(binding)), .text(binding.scope.ownerUserID), .text(binding.scope.notebookID.uuidString.lowercased()),
                    .text(binding.scope.replicaID.uuidString.lowercased())]) == 1 else { throw LingroveNotebookSyncStoreError.scopeChanged }
            let closures = LingroveNotebookUploadClosureStore(core: core)
            if let rejection = authorization.rejectionID {
                try core.execute(sql: "UPDATE notebook_sync_rejections SET authorized_generation=? WHERE workspace_id=? AND group_id=?",
                    values: [.text(binding.generation), .text(workspace(binding)), .text(rejection)])
            }
            for group in authorization.completedGroups {
                _ = try closures.resumeCompletedInTransaction(groupID: group, cancelRevision: nil, binding: binding)
            }
            if let target = authorization.pending {
                let changed = try core.execute(sql: """
                    UPDATE notebook_upload_retry_intents SET resume_revision=cancel_revision
                    WHERE workspace_id=? AND frozen_sha256=? AND group_id=? AND cancel_revision=?
                    """, values: [.text(workspace(binding)), .text(target.frozenSHA256), .text(target.groupID.uuidString.lowercased()), .integer(target.cancelRevision)])
                if changed == 0 {
                    // The body may have been retired while this click awaited
                    // SQLite. Only its exact cancellation revision may resume.
                    let outcome = try core.scalarInt(sql: """
                        SELECT (SELECT count(*) FROM notebook_upload_receipts WHERE workspace_id=? AND group_id=?) +
                               (SELECT count(*) FROM notebook_upload_rejections WHERE workspace_id=? AND group_id=?) +
                               (SELECT count(*) FROM notebook_staged_upload_outcomes WHERE workspace_id=? AND group_id=?)
                        """, values: [.text(workspace(binding)), .text(target.groupID.uuidString.lowercased()),
                            .text(workspace(binding)), .text(target.groupID.uuidString.lowercased()), .text(workspace(binding)), .text(target.groupID.uuidString.lowercased())])
                    if outcome == 0 { _ = try closures.resumeCompletedInTransaction(groupID: target.groupID, cancelRevision: target.cancelRevision, binding: binding) }
                }
            }
        }
    }
    private func state(_ statement: OpaquePointer, cancelIndex: Int32, resumeIndex: Int32, cancelRequested: Bool) throws -> LingroveNotebookRetryState {
        guard sqlite3_column_type(statement, cancelIndex) == SQLITE_INTEGER else { throw LingroveNotebookUploadStoreError.corruptBatch }
        let cancel = sqlite3_column_int64(statement, cancelIndex)
        let resume: Int64?
        if sqlite3_column_type(statement, resumeIndex) == SQLITE_NULL { resume = nil }
        else {
            guard sqlite3_column_type(statement, resumeIndex) == SQLITE_INTEGER else { throw LingroveNotebookUploadStoreError.corruptBatch }
            resume = sqlite3_column_int64(statement, resumeIndex)
        }
        guard cancel >= 0, cancelRequested == (cancel > 0), resume.map({ $0 > 0 && $0 <= cancel }) ?? true else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return .init(cancelRevision: cancel, resumeRevision: resume)
    }
    private func workspace(_ binding: LingroveNotebookWindowBinding) -> String { binding.scope.workspaceID.uuidString.lowercased() }
    private func text(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, index),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), encoding: .utf8) else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return value
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
