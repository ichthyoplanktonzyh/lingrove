import CryptoKit
import Foundation
import LingroveNotebookSync
import SQLite3

/// This adapter borrows UploadStore's existing transaction and connection. It
/// owns mutable cancellation/negative state and compact completed outcomes;
/// editable corpus rows and journal retirement remain with their own stores.
public struct LingroveNotebookUploadTerminalStore {
    public let core: DatabaseCore

    public func initializeInTransaction(workspaceID: String, frozenSHA256: String) throws {
        try core.execute(sql: "INSERT INTO notebook_upload_terminal_state(workspace_id,frozen_sha256,cancel_requested) VALUES(?,?,0)",
            values: [.text(workspaceID), .text(frozenSHA256)])
    }

    public func readInTransaction(workspaceID: String, frozenSHA256: String, batch: VocabularyWireUploadBatch) throws -> (cancelRequested: Bool, rejection: VocabularyWireGroupRejection?) {
        let rows = try core.query(sql: "SELECT frozen_sha256,cancel_requested,rejection_json,rejection_sha256 FROM notebook_upload_terminal_state WHERE workspace_id=?",
            values: [.text(workspaceID)]) { statement in
            guard try text(statement, 0) == frozenSHA256, sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  [0,1].contains(sqlite3_column_int64(statement, 1)) else { throw LingroveNotebookUploadStoreError.corruptBatch }
            var rejection: VocabularyWireGroupRejection?
            if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                let json = try text(statement, 2)
                guard try sha256(Data(json.utf8)) == text(statement, 3) else { throw LingroveNotebookUploadStoreError.corruptBatch }
                rejection = try JSONDecoder().decode(VocabularyWireGroupRejection.self, from: Data(json.utf8))
                try rejection?.validate(for: batch)
            } else if sqlite3_column_type(statement, 3) != SQLITE_NULL { throw LingroveNotebookUploadStoreError.corruptBatch }
            return (sqlite3_column_int64(statement, 1) == 1, rejection)
        }
        guard rows.count == 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return rows[0]
    }

    public func requestCancellationInTransaction(_ pending: LingroveNotebookPendingUpload) throws {
        guard pending.receipt == nil, pending.rejection == nil else { return }
        let changed = try core.execute(sql: "UPDATE notebook_upload_terminal_state SET cancel_requested=1 WHERE workspace_id=? AND frozen_sha256=?",
            values: [.text(pending.batch.scope.workspaceID.uuidString.lowercased()), .text(pending.frozenSHA256)])
        guard changed == 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
        try LingroveNotebookRetryStore(core: core).cancelInTransaction(pending)
    }

    public func recordInTransaction(_ rejection: VocabularyWireGroupRejection, pending: LingroveNotebookPendingUpload) throws {
        let json = try core.encodeJsonString(value: rejection)
        let changed = try core.execute(sql: """
            UPDATE notebook_upload_terminal_state SET rejection_json=?,rejection_sha256=?
            WHERE workspace_id=? AND frozen_sha256=? AND rejection_json IS NULL
            """, values: [.text(json), .text(sha256(Data(json.utf8))), .text(pending.batch.scope.workspaceID.uuidString.lowercased()), .text(pending.frozenSHA256)])
        guard changed == 1 else { throw LingroveNotebookUploadStoreError.receiptConflict }
    }

    /// Both ledgers are checked together. A late positive callback may not
    /// contradict a completed negative decision even when a newer batch exists.
    public func completedInTransaction(groupID: UUID, bodySHA256: String, binding: LingroveNotebookWindowBinding,
                                localNotebookID: UUID) throws -> VocabularyWireGroupOutcome? {
        let rows = try core.query(sql: """
            SELECT local_notebook_id,owner_user_id,remote_notebook_id,replica_id,body_sha256,receipt_json,'committed'
            FROM notebook_upload_receipts WHERE workspace_id=? AND group_id=?
            UNION ALL
            SELECT local_notebook_id,owner_user_id,remote_notebook_id,replica_id,body_sha256,rejection_json,'rejected'
            FROM notebook_upload_rejections WHERE workspace_id=? AND group_id=?
            """, values: [.text(binding.scope.workspaceID.uuidString.lowercased()), .text(groupID.uuidString.lowercased()),
                          .text(binding.scope.workspaceID.uuidString.lowercased()), .text(groupID.uuidString.lowercased())]) { statement in
            guard UUID(uuidString: try text(statement, 0)) == localNotebookID,
                  (try text(statement, 1)).utf8.elementsEqual(binding.scope.ownerUserID.utf8),
                  UUID(uuidString: try text(statement, 2)) == binding.scope.notebookID,
                  UUID(uuidString: try text(statement, 3)) == binding.scope.replicaID,
                  try text(statement, 4) == bodySHA256 else { throw LingroveNotebookUploadStoreError.receiptConflict }
            let bytes = Data(try text(statement, 5).utf8)
            if try text(statement, 6) == "committed" {
                let receipt = try JSONDecoder().decode(VocabularyWireGroupReceipt.self, from: bytes)
                guard receipt.groupID == groupID, receipt.notebookID == binding.scope.notebookID else { throw LingroveNotebookUploadStoreError.corruptBatch }
                return VocabularyWireGroupOutcome.committed(receipt)
            }
            let rejection = try JSONDecoder().decode(VocabularyWireGroupRejection.self, from: bytes)
            guard rejection.groupID == groupID, rejection.notebookID == binding.scope.notebookID else { throw LingroveNotebookUploadStoreError.corruptBatch }
            return VocabularyWireGroupOutcome.rejected(rejection)
        }
        guard rows.count <= 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return rows.first
    }

    /// A verified pull/rebase retires only the rejected frozen body. Every
    /// corpus journal remains pending because no public write was acknowledged.
    public func finishRejectedInTransaction(_ pending: LingroveNotebookPendingUpload, localNotebookID: UUID) throws {
        guard let rejection = pending.rejection, pending.receipt == nil else { throw LingroveNotebookUploadStoreError.awaitingReceipt }
        let scope = pending.batch.scope
        try core.execute(sql: """
            INSERT INTO notebook_upload_rejections(workspace_id,group_id,local_notebook_id,owner_user_id,remote_notebook_id,replica_id,body_sha256,rejection_json,created_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, values: [.text(scope.workspaceID.uuidString.lowercased()), .text(rejection.groupID.uuidString.lowercased()), .text(localNotebookID.uuidString),
                .text(scope.ownerUserID), .text(scope.notebookID.uuidString.lowercased()), .text(scope.replicaID.uuidString.lowercased()),
                .text(pending.bodySHA256), .text(try core.encodeJsonString(value: rejection)), .text(nowIsoTimestamp())])
        let removed = try core.execute(sql: "DELETE FROM notebook_upload_batches WHERE workspace_id=? AND frozen_sha256=?",
            values: [.text(scope.workspaceID.uuidString.lowercased()), .text(pending.frozenSHA256)])
        guard removed == 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
    }

    private func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
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
