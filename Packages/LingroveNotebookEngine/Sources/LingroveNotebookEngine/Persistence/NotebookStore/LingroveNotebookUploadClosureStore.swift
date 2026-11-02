import CryptoKit
import Foundation
import LingroveNotebookSync
import SQLite3

/// LocalDatabase lends this adapter its connection. It owns only transport
/// closure metadata and the durable retry gate. UploadStore owns frozen intent;
/// SyncStore must first rebase a verified window before this adapter can retire
/// an unusable transport identity. No method acknowledges a corpus journal.
public struct LingroveNotebookUploadClosureStore {
    public let core: DatabaseCore

    public func initializeInTransaction(workspaceID: String, frozenSHA256: String) throws {
        try core.execute(sql: "INSERT INTO notebook_upload_transport_state(workspace_id,frozen_sha256) VALUES(?,?)",
            values: [.text(workspaceID), .text(frozenSHA256)])
    }

    public func readInTransaction(upload: VocabularyWireStagedUpload, frozenSHA256: String) throws -> VocabularyWireStagedClosure? {
        let rows = try core.query(sql: "SELECT frozen_sha256,closure_json,closure_sha256 FROM notebook_upload_transport_state WHERE workspace_id=?",
            values: [.text(upload.batch.scope.workspaceID.uuidString.lowercased())]) { statement -> VocabularyWireStagedClosure? in
            guard try text(statement, 0) == frozenSHA256 else { throw LingroveNotebookUploadStoreError.corruptBatch }
            guard sqlite3_column_type(statement, 1) != SQLITE_NULL else {
                guard sqlite3_column_type(statement, 2) == SQLITE_NULL else { throw LingroveNotebookUploadStoreError.corruptBatch }
                return nil
            }
            let closure = try decodedClosure(statement, jsonIndex: 1, hashIndex: 2)
            try closure.validate(for: upload)
            return closure
        }
        guard rows.count == 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return rows[0]
    }

    public func record(_ closure: VocabularyWireStagedClosure, pending: LingroveNotebookPendingUpload,
                binding: LingroveNotebookWindowBinding) throws {
        let upload = try envelope(pending, binding: binding); try closure.validate(for: upload)
        try core.inTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            if let done = try completedInTransaction(groupID: closure.groupID, binding: binding, localNotebookID: nil) {
                guard done.closure == closure else { throw LingroveNotebookUploadStoreError.receiptConflict }
                return
            }
            try requireNoGroupOutcome(groupID: closure.groupID, workspaceID: workspace(binding))
            let rows = try core.query(sql: """
                SELECT u.frozen_sha256,s.frozen_sha256,s.descriptor_sha256,s.manifest_json
                FROM notebook_upload_batches u JOIN notebook_staged_uploads s USING(workspace_id)
                WHERE u.workspace_id=? AND u.transport_kind='staged'
                """, values: [.text(workspace(binding))]) { statement in
                guard try text(statement, 0) == pending.frozenSHA256, try text(statement, 1) == pending.frozenSHA256,
                      try text(statement, 2) == upload.descriptorSHA256, sqlite3_column_type(statement, 3) == SQLITE_NULL else {
                    throw LingroveNotebookUploadStoreError.receiptConflict
                }
                return true
            }
            guard rows.count == 1, pending.outcome == nil else { throw LingroveNotebookUploadStoreError.receiptConflict }
            let old = try readInTransaction(upload: upload, frozenSHA256: pending.frozenSHA256)
            if let old {
                guard old == closure else { throw LingroveNotebookUploadStoreError.receiptConflict }
                return
            }
            guard try core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_confirmation_pages WHERE workspace_id=?", values: [.text(workspace(binding))]) == 0 else {
                throw LingroveNotebookUploadStoreError.corruptBatch
            }
            let json = try core.encodeJsonString(value: closure)
            guard try core.execute(sql: "UPDATE notebook_upload_transport_state SET closure_json=?,closure_sha256=? WHERE workspace_id=? AND frozen_sha256=? AND closure_json IS NULL",
                values: [.text(json), .text(hash(json)), .text(workspace(binding)), .text(pending.frozenSHA256)]) == 1 else {
                throw LingroveNotebookUploadStoreError.receiptConflict
            }
        }
    }

    public func hasCompletedInTransaction(groupID: UUID, binding: LingroveNotebookWindowBinding) throws -> Bool {
        try core.scalarInt(sql: "SELECT count(*) FROM notebook_completed_upload_closures WHERE workspace_id=? AND group_id=?",
            values: [.text(workspace(binding)), .text(groupID.uuidString.lowercased())]) != 0
    }

    public func isFinishedInTransaction(_ pending: LingroveNotebookPendingUpload, localNotebookID: UUID,
                                 binding: LingroveNotebookWindowBinding) throws -> Bool {
        guard let closure = pending.stagedClosure else { return false }
        if let done = try completedInTransaction(groupID: closure.groupID, binding: binding, localNotebookID: localNotebookID) {
            try done.closure.validate(for: envelope(pending, binding: binding))
            guard done.closure == closure else { throw LingroveNotebookUploadStoreError.receiptConflict }
            return true
        }
        return false
    }

    /// The covering apply owns this transaction. Closure retirement deliberately
    /// skips UploadStore.retireCoverage: the server never accepted those writes.
    public func finishInTransaction(_ pending: LingroveNotebookPendingUpload, localNotebookID: UUID, blockedJournalRevision: Int64) throws {
        guard let closure = pending.stagedClosure, let upload = pending.stagedUpload, pending.outcome == nil,
              pending.confirmationManifest == nil, let retry = pending.retryIntent, blockedJournalRevision >= 0 else { throw LingroveNotebookUploadStoreError.awaitingReceipt }
        try closure.validate(for: upload)
        let scope = pending.batch.scope, workspaceID = scope.workspaceID.uuidString.lowercased()
        try requireNoGroupOutcome(groupID: closure.groupID, workspaceID: workspaceID)
        let json = try core.encodeJsonString(value: closure)
        try core.execute(sql: """
            INSERT INTO notebook_completed_upload_closures(workspace_id,group_id,local_notebook_id,owner_user_id,remote_notebook_id,replica_id,
              body_sha256,closure_json,closure_sha256,blocked_journal_revision,retry_blocked,cancel_requested,cancel_revision,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, values: [.text(workspaceID), .text(closure.groupID.uuidString.lowercased()), .text(localNotebookID.uuidString), .text(scope.ownerUserID),
                .text(scope.notebookID.uuidString.lowercased()), .text(scope.replicaID.uuidString.lowercased()), .text(upload.bodySHA256),
                .text(json), .text(hash(json)), .integer(blockedJournalRevision), .integer(pending.cancelRequested && !retry.isResumed ? 1 : 0),
                .integer(pending.cancelRequested ? 1 : 0), .integer(retry.cancelRevision), .text(nowIsoTimestamp())])
        guard try core.execute(sql: "DELETE FROM notebook_upload_batches WHERE workspace_id=? AND frozen_sha256=?",
            values: [.text(workspaceID), .text(pending.frozenSHA256)]) == 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
    }

    /// A remote apply can change document revision, but creates no new journal.
    /// Gate on journals explicitly classified as public content changes, so
    /// background pulls, private receipts and timestamps cannot undo a cancel.
    /// New public intent or explicit retry authorizes a fresh identity.
    public func checkRetryInTransaction(binding: LingroveNotebookWindowBinding, localNotebookID: UUID, journalRevision: Int64) throws {
        let groups = try core.query(sql: "SELECT group_id FROM notebook_completed_upload_closures WHERE workspace_id=? AND retry_blocked=1",
            values: [.text(workspace(binding))]) { statement in
            guard let id = UUID(uuidString: try text(statement, 0)) else { throw LingroveNotebookUploadStoreError.corruptBatch }
            return id
        }
        for group in groups {
            guard let done = try completedInTransaction(groupID: group, binding: binding, localNotebookID: localNotebookID) else {
                throw LingroveNotebookUploadStoreError.corruptBatch
            }
            if done.blocked && journalRevision <= done.revision { throw LingroveNotebookUploadStoreError.cancelledUpload }
        }
    }

    /// The explicit retry action is itself durable user authorization. Once
    /// this transaction succeeds, a restart may attempt a fresh freeze. By
    /// contrast, automatic unblocking after a new edit clears the gate only
    /// inside that freeze/no-diff transaction, so its failures retain the gate.
    public func resume(binding: LingroveNotebookWindowBinding) throws {
        let store = LingroveNotebookRetryStore(core: core)
        if let authorization = try store.captureKnown(binding) {
            guard authorization.binding.scope == binding.scope else { throw LingroveNotebookSyncStoreError.scopeChanged }
            try store.authorize(authorization)
        }
    }
    public func resumeCompletedInTransaction(groupID: UUID, cancelRevision: Int64?, binding: LingroveNotebookWindowBinding) throws -> Bool {
        guard let done = try completedInTransaction(groupID: groupID, binding: binding, localNotebookID: nil),
              cancelRevision == nil || cancelRevision == done.cancelRevision else { return false }
        try core.execute(sql: "UPDATE notebook_completed_upload_closures SET retry_blocked=0 WHERE workspace_id=? AND group_id=?",
            values: [.text(workspace(binding)), .text(groupID.uuidString.lowercased())])
        return true
    }
    public func clearRetryInTransaction(binding: LingroveNotebookWindowBinding) throws {
        try core.execute(sql: "UPDATE notebook_completed_upload_closures SET retry_blocked=0 WHERE workspace_id=?",
            values: [.text(workspace(binding))])
    }

    private func completedInTransaction(groupID: UUID, binding: LingroveNotebookWindowBinding, localNotebookID: UUID?) throws
        -> (closure: VocabularyWireStagedClosure, blocked: Bool, revision: Int64, cancelRevision: Int64)? {
        try requireNoGroupOutcome(groupID: groupID, workspaceID: workspace(binding))
        let currentID = try core.scalarText(sql: "SELECT notebook_id FROM notebook_state WHERE workspace_id=?", values: [.text(workspace(binding))])
        let rows = try core.query(sql: """
            SELECT local_notebook_id,owner_user_id,remote_notebook_id,replica_id,body_sha256,closure_json,closure_sha256,blocked_journal_revision,retry_blocked,cancel_requested,cancel_revision
            FROM notebook_completed_upload_closures WHERE workspace_id=? AND group_id=?
            """, values: [.text(workspace(binding)), .text(groupID.uuidString.lowercased())]) { statement in
            let local = UUID(uuidString: try text(statement, 0))
            let closure = try decodedClosure(statement, jsonIndex: 5, hashIndex: 6)
            guard let local, local == UUID(uuidString: currentID), localNotebookID == nil || local == localNotebookID,
                  (try text(statement, 1)).utf8.elementsEqual(binding.scope.ownerUserID.utf8),
                  UUID(uuidString: try text(statement, 2)) == binding.scope.notebookID,
                  UUID(uuidString: try text(statement, 3)) == binding.scope.replicaID,
                  closure.scope == binding.scope, closure.groupID == groupID, try text(statement, 4) == closure.bodySHA256,
                  sqlite3_column_type(statement, 7) == SQLITE_INTEGER, sqlite3_column_int64(statement, 7) >= 0,
                  sqlite3_column_type(statement, 8) == SQLITE_INTEGER, [0,1].contains(sqlite3_column_int64(statement, 8)),
                  sqlite3_column_type(statement, 9) == SQLITE_INTEGER, [0,1].contains(sqlite3_column_int64(statement, 9)),
                  sqlite3_column_int64(statement, 8) <= sqlite3_column_int64(statement, 9), sqlite3_column_type(statement, 10) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 10) >= 0,
                  (sqlite3_column_int64(statement, 10) > 0) == (sqlite3_column_int64(statement, 9) == 1) else { throw LingroveNotebookUploadStoreError.corruptBatch }
            return (closure, sqlite3_column_int64(statement, 8) == 1, sqlite3_column_int64(statement, 7), sqlite3_column_int64(statement, 10))
        }
        return rows.first
    }
    private func requireNoGroupOutcome(groupID: UUID, workspaceID: String) throws {
        let group = groupID.uuidString.lowercased()
        let count = try core.scalarInt(sql: """
            SELECT (SELECT count(*) FROM notebook_upload_receipts WHERE workspace_id=? AND group_id=?) +
                   (SELECT count(*) FROM notebook_upload_rejections WHERE workspace_id=? AND group_id=?) +
                   (SELECT count(*) FROM notebook_staged_upload_outcomes WHERE workspace_id=? AND group_id=?)
            """, values: [.text(workspaceID), .text(group), .text(workspaceID), .text(group), .text(workspaceID), .text(group)])
        guard count == 0 else { throw LingroveNotebookUploadStoreError.receiptConflict }
    }
    private func envelope(_ pending: LingroveNotebookPendingUpload, binding: LingroveNotebookWindowBinding) throws -> VocabularyWireStagedUpload {
        guard pending.batch.transport == .staged, pending.batch.scope == binding.scope, let upload = pending.stagedUpload else {
            throw LingroveNotebookUploadStoreError.receiptConflict
        }
        return upload
    }
    private func decodedClosure(_ statement: OpaquePointer, jsonIndex: Int32, hashIndex: Int32) throws -> VocabularyWireStagedClosure {
        let json = try text(statement, jsonIndex)
        guard json.utf8.count <= 16 * 1024, try hash(json) == text(statement, hashIndex) else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return try JSONDecoder().decode(VocabularyWireStagedClosure.self, from: Data(json.utf8))
    }
    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func workspace(_ binding: LingroveNotebookWindowBinding) -> String { binding.scope.workspaceID.uuidString.lowercased() }
    private func text(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, index),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), encoding: .utf8) else {
            throw LingroveNotebookUploadStoreError.corruptBatch
        }
        return value
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
