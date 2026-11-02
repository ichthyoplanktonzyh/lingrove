import CryptoKit
import Foundation
import LingroveNotebookSync
import SQLite3

/// LocalDatabase lends this adapter its connection. Frozen request/coverage
/// ownership stays in UploadStore; this child owns bounded confirmation pages
/// and compact completed decisions. A network callback uses its immutable
/// pending ticket, then checks generation and frozen identity inside the write.
public struct LingroveNotebookStagedUploadStore {
    public let core: DatabaseCore

    public func initializeInTransaction(upload: VocabularyWireStagedUpload, frozenSHA256: String) throws {
        try core.execute(sql: "INSERT INTO notebook_staged_uploads(workspace_id,frozen_sha256,descriptor_sha256) VALUES(?,?,?)",
            values: [.text(upload.batch.scope.workspaceID.uuidString.lowercased()), .text(frozenSHA256), .text(upload.descriptorSHA256)])
        try LingroveNotebookUploadClosureStore(core: core).initializeInTransaction(workspaceID: upload.batch.scope.workspaceID.uuidString.lowercased(), frozenSHA256: frozenSHA256)
        try LingroveNotebookRetryStore(core: core).initializeInTransaction(upload: upload, frozenSHA256: frozenSHA256)
    }

    /// Reopening checks the whole immutable envelope once, then streams stored
    /// pages through the same verifier used by networking. Partial pages never
    /// become a receipt. Only page ordinals, not a second UUID array, are kept.
    public func readInTransaction(upload: VocabularyWireStagedUpload?, workspaceID: String, frozenSHA256: String) throws
        -> (manifest: VocabularyWireConfirmationManifest?, ordinals: [Int], outcome: VocabularyWireGroupOutcome?) {
        guard let upload else {
            guard try core.scalarInt(sql: "SELECT count(*) FROM notebook_staged_uploads WHERE workspace_id=?", values: [.text(workspaceID)]) == 0 else {
                throw LingroveNotebookUploadStoreError.corruptBatch
            }
            return (nil, [], nil)
        }
        let manifest = try headerInTransaction(upload: upload, workspaceID: workspaceID, frozenSHA256: frozenSHA256)
        guard let manifest else {
            guard try core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_confirmation_pages WHERE workspace_id=?", values: [.text(workspaceID)]) == 0 else {
                throw LingroveNotebookUploadStoreError.corruptBatch
            }
            return (nil, [], nil)
        }
        var verifier = try VocabularyWireConfirmationAccumulator(manifest: manifest, expecting: upload)
        let ordinals = try core.query(sql: "SELECT ordinal,page_json,page_sha256 FROM notebook_upload_confirmation_pages WHERE workspace_id=? ORDER BY ordinal",
            values: [.text(workspaceID)]) { statement in
            let page = try checkedPage(statement, jsonIndex: 1, hashIndex: 2)
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER, sqlite3_column_int64(statement, 0) == Int64(page.ordinal) else {
                throw LingroveNotebookUploadStoreError.corruptBatch
            }
            _ = try verifier.accept(page)
            return page.ordinal
        }
        return (manifest, ordinals, ordinals.count == manifest.pageCount ? try verifier.finish().outcome : nil)
    }

    public func recordManifest(_ manifest: VocabularyWireConfirmationManifest, pending: LingroveNotebookPendingUpload,
                        binding: LingroveNotebookWindowBinding) throws {
        let upload = try envelope(pending, binding: binding)
        try manifest.validate(for: upload)
        try core.inTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            if try isFinishedInTransaction(pending, manifest: manifest, localNotebookID: nil, binding: binding) { return }
            try checkFrozenInTransaction(pending, binding: binding)
            let old = try headerInTransaction(upload: upload, workspaceID: workspace(binding), frozenSHA256: pending.frozenSHA256)
            if let old {
                guard old == manifest else { throw LingroveNotebookUploadStoreError.receiptConflict }
                return
            }
            let json = try core.encodeJsonString(value: manifest)
            let changed = try core.execute(sql: """
                UPDATE notebook_staged_uploads SET manifest_json=?,manifest_sha256=?
                WHERE workspace_id=? AND frozen_sha256=? AND manifest_json IS NULL
                """, values: [.text(json), .text(hash(json)), .text(workspace(binding)), .text(pending.frozenSHA256)])
            guard changed == 1 else { throw LingroveNotebookUploadStoreError.receiptConflict }
        }
    }

    /// Page-local verification uses the already restored envelope and its UUID
    /// slice, avoiding a large body parse/hash for every page callback. SQLite
    /// then checks immutable ticket + manifest and admits only the next page.
    public func recordPage(_ page: VocabularyWireConfirmationPage, manifest: VocabularyWireConfirmationManifest,
                    pending: LingroveNotebookPendingUpload, binding: LingroveNotebookWindowBinding) throws {
        let upload = try envelope(pending, binding: binding)
        try page.validate(for: manifest, upload: upload)
        try core.inTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            if try isFinishedInTransaction(pending, manifest: manifest, localNotebookID: nil, binding: binding) { return }
            try checkFrozenInTransaction(pending, binding: binding)
            guard try headerInTransaction(upload: upload, workspaceID: workspace(binding), frozenSHA256: pending.frozenSHA256) == manifest else {
                throw LingroveNotebookUploadStoreError.receiptConflict
            }
            let prior = try core.query(sql: "SELECT page_json,page_sha256 FROM notebook_upload_confirmation_pages WHERE workspace_id=? AND ordinal=?",
                values: [.text(workspace(binding)), .integer(Int64(page.ordinal))]) { try checkedPage($0, jsonIndex: 0, hashIndex: 1) }
            if let prior = prior.first {
                guard prior == page else { throw LingroveNotebookUploadStoreError.receiptConflict }
                return
            }
            let count = try core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_confirmation_pages WHERE workspace_id=?", values: [.text(workspace(binding))])
            guard count == page.ordinal else { throw VocabularyWireStagedError.invalidPage }
            let json = try core.encodeJsonString(value: page)
            try core.execute(sql: "INSERT INTO notebook_upload_confirmation_pages(workspace_id,ordinal,page_json,page_sha256) VALUES(?,?,?,?)",
                values: [.text(workspace(binding)), .integer(Int64(page.ordinal)), .text(json), .text(hash(json))])
        }
    }

    public func hasCompletedInTransaction(groupID: UUID, binding: LingroveNotebookWindowBinding) throws -> Bool {
        try core.scalarInt(sql: "SELECT count(*) FROM notebook_staged_upload_outcomes WHERE workspace_id=? AND group_id=?",
            values: [.text(workspace(binding)), .text(groupID.uuidString.lowercased())]) != 0
    }

    public func isFinishedInTransaction(_ pending: LingroveNotebookPendingUpload, localNotebookID: UUID,
                                 binding: LingroveNotebookWindowBinding) throws -> Bool {
        guard pending.outcome != nil, let manifest = pending.confirmationManifest else { return false }
        return try isFinishedInTransaction(pending, manifest: manifest, localNotebookID: localNotebookID, binding: binding)
    }

    /// The caller already rebased a covering window in this transaction. It
    /// alone retires positive coverage; rejected journals are never retired.
    /// The compact ledger can compare late callbacks without decoding >10k IDs.
    public func finishInTransaction(_ pending: LingroveNotebookPendingUpload, localNotebookID: UUID) throws {
        guard pending.outcome != nil, let upload = pending.stagedUpload, let manifest = pending.confirmationManifest,
              pending.receivedConfirmationOrdinals.count == manifest.pageCount else { throw LingroveNotebookUploadStoreError.awaitingReceipt }
        let scope = pending.batch.scope, workspaceID = scope.workspaceID.uuidString.lowercased(), groupID = pending.batch.request.groupID.uuidString.lowercased()
        let ordinary = try core.scalarInt(sql: """
            SELECT (SELECT count(*) FROM notebook_upload_receipts WHERE workspace_id=? AND group_id=?) +
                   (SELECT count(*) FROM notebook_upload_rejections WHERE workspace_id=? AND group_id=?) +
                   (SELECT count(*) FROM notebook_completed_upload_closures WHERE workspace_id=? AND group_id=?)
            """, values: [.text(workspaceID), .text(groupID), .text(workspaceID), .text(groupID), .text(workspaceID), .text(groupID)])
        guard ordinary == 0 else { throw LingroveNotebookUploadStoreError.receiptConflict }
        let json = try core.encodeJsonString(value: manifest)
        try core.execute(sql: """
            INSERT INTO notebook_staged_upload_outcomes(workspace_id,group_id,local_notebook_id,owner_user_id,remote_notebook_id,replica_id,body_sha256,manifest_json,manifest_sha256,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, values: [.text(workspaceID), .text(groupID), .text(localNotebookID.uuidString), .text(scope.ownerUserID),
                .text(scope.notebookID.uuidString.lowercased()), .text(scope.replicaID.uuidString.lowercased()), .text(upload.bodySHA256),
                .text(json), .text(hash(json)), .text(nowIsoTimestamp())])
        guard try core.execute(sql: "DELETE FROM notebook_upload_batches WHERE workspace_id=? AND frozen_sha256=?",
            values: [.text(workspaceID), .text(pending.frozenSHA256)]) == 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
    }

    private func isFinishedInTransaction(_ pending: LingroveNotebookPendingUpload, manifest: VocabularyWireConfirmationManifest,
                                         localNotebookID: UUID?, binding: LingroveNotebookWindowBinding) throws -> Bool {
        let upload = try envelope(pending, binding: binding)
        let closures = LingroveNotebookUploadClosureStore(core: core)
        guard try !closures.hasCompletedInTransaction(groupID: manifest.groupID, binding: binding) else { throw LingroveNotebookUploadStoreError.receiptConflict }
        let ordinary = try core.scalarInt(sql: """
            SELECT (SELECT count(*) FROM notebook_upload_receipts WHERE workspace_id=? AND group_id=?) +
                   (SELECT count(*) FROM notebook_upload_rejections WHERE workspace_id=? AND group_id=?)
            """, values: [.text(workspace(binding)), .text(pending.batch.request.groupID.uuidString.lowercased()),
                .text(workspace(binding)), .text(pending.batch.request.groupID.uuidString.lowercased())])
        guard ordinary == 0 else { throw LingroveNotebookUploadStoreError.receiptConflict }
        let rows = try core.query(sql: """
            SELECT local_notebook_id,owner_user_id,remote_notebook_id,replica_id,body_sha256,manifest_json,manifest_sha256
            FROM notebook_staged_upload_outcomes WHERE workspace_id=? AND group_id=?
            """, values: [.text(workspace(binding)), .text(pending.batch.request.groupID.uuidString.lowercased())]) { statement in
            let localID = try UUID(uuidString: text(statement, 0))
            let currentLocalID = try core.scalarText(sql: "SELECT notebook_id FROM notebook_state WHERE workspace_id=?", values: [.text(workspace(binding))])
            guard let localID, localID == UUID(uuidString: currentLocalID), localNotebookID == nil || localNotebookID == localID,
                  (try text(statement, 1)).utf8.elementsEqual(binding.scope.ownerUserID.utf8),
                  UUID(uuidString: try text(statement, 2)) == binding.scope.notebookID,
                  UUID(uuidString: try text(statement, 3)) == binding.scope.replicaID,
                  try text(statement, 4) == upload.bodySHA256 else { throw LingroveNotebookUploadStoreError.receiptConflict }
            let json = try text(statement, 5)
            guard json.utf8.count <= 16 * 1024, try hash(json) == text(statement, 6) else { throw LingroveNotebookUploadStoreError.corruptBatch }
            let stored = try JSONDecoder().decode(VocabularyWireConfirmationManifest.self, from: Data(json.utf8))
            try stored.validate(for: upload)
            guard stored == manifest else { throw LingroveNotebookUploadStoreError.receiptConflict }
            return true
        }
        return rows.first ?? false
    }

    private func headerInTransaction(upload: VocabularyWireStagedUpload, workspaceID: String, frozenSHA256: String) throws -> VocabularyWireConfirmationManifest? {
        let rows = try core.query(sql: "SELECT frozen_sha256,descriptor_sha256,manifest_json,manifest_sha256 FROM notebook_staged_uploads WHERE workspace_id=?",
            values: [.text(workspaceID)]) { statement -> VocabularyWireConfirmationManifest? in
            guard try text(statement, 0) == frozenSHA256, try text(statement, 1) == upload.descriptorSHA256 else { throw LingroveNotebookUploadStoreError.corruptBatch }
            if try LingroveNotebookUploadClosureStore(core: core).readInTransaction(upload: upload, frozenSHA256: frozenSHA256) != nil,
               sqlite3_column_type(statement, 2) != SQLITE_NULL { throw LingroveNotebookUploadStoreError.receiptConflict }
            guard sqlite3_column_type(statement, 2) != SQLITE_NULL else {
                guard sqlite3_column_type(statement, 3) == SQLITE_NULL else { throw LingroveNotebookUploadStoreError.corruptBatch }
                return nil
            }
            let json = try text(statement, 2)
            guard json.utf8.count <= 16 * 1024, try hash(json) == text(statement, 3) else { throw LingroveNotebookUploadStoreError.corruptBatch }
            let manifest = try JSONDecoder().decode(VocabularyWireConfirmationManifest.self, from: Data(json.utf8))
            try manifest.validate(for: upload)
            return manifest
        }
        guard rows.count == 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return rows[0]
    }

    private func checkFrozenInTransaction(_ pending: LingroveNotebookPendingUpload, binding: LingroveNotebookWindowBinding) throws {
        guard let upload = pending.stagedUpload,
              try LingroveNotebookUploadClosureStore(core: core).readInTransaction(upload: upload, frozenSHA256: pending.frozenSHA256) == nil else {
            throw LingroveNotebookUploadStoreError.receiptConflict
        }
        let matches = try core.scalarInt(sql: "SELECT count(*) FROM notebook_upload_batches WHERE workspace_id=? AND frozen_sha256=? AND transport_kind='staged'",
            values: [.text(workspace(binding)), .text(pending.frozenSHA256)])
        guard matches == 1 else { throw LingroveNotebookUploadStoreError.receiptConflict }
    }
    private func envelope(_ pending: LingroveNotebookPendingUpload, binding: LingroveNotebookWindowBinding) throws -> VocabularyWireStagedUpload {
        guard pending.batch.transport == .staged, pending.batch.scope == binding.scope, let upload = pending.stagedUpload else {
            throw LingroveNotebookUploadStoreError.receiptConflict
        }
        return upload
    }
    private func checkedPage(_ statement: OpaquePointer, jsonIndex: Int32, hashIndex: Int32) throws -> VocabularyWireConfirmationPage {
        let json = try text(statement, jsonIndex)
        guard try hash(json) == text(statement, hashIndex), json.utf8.count <= 256 * 1024 else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return try JSONDecoder().decode(VocabularyWireConfirmationPage.self, from: Data(json.utf8))
    }
    private func hash(_ json: String) -> String { SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined() }
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
