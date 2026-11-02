import CryptoKit
import Foundation
import LingroveNotebook
import LingroveNotebookSync
import SQLite3

/// Frozen journal identities are local bookkeeping, never remote payloads.
/// Their exact header values fence retirement against unrelated or newer edits.
private struct LingroveNotebookUploadCoverage: Codable, Equatable, Sendable {
    let operationID: String
    let notebookID: String
    let baseRevision: Int64
    let revision: Int64
    let hasTemplates: Int64
    let createdAt: String
}

/// A request can cross the networking task boundary as immutable bytes. Only
/// this file creates the persisted wrapper; the shared planner validates its
/// public target independently from the locally retained journal coverage.
public nonisolated struct LingroveNotebookPendingUpload: Sendable {
    public let batch: VocabularyWireUploadBatch
    public let body: Data
    public let receipt: VocabularyWireGroupReceipt?
    public let rejection: VocabularyWireGroupRejection?
    public let cancelRequested: Bool
    public let frozenSHA256: String
    public let stagedUpload: VocabularyWireStagedUpload?
    public let confirmationManifest: VocabularyWireConfirmationManifest?
    public let receivedConfirmationOrdinals: [Int]
    public let stagedClosure: VocabularyWireStagedClosure?
    public let retryIntent: LingroveNotebookRetryState?
    fileprivate let coverage: [LingroveNotebookUploadCoverage]
    public var bodySHA256: String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }
    public var outcome: VocabularyWireGroupOutcome? {
        if let receipt { return .committed(receipt) }
        if let rejection { return .rejected(rejection) }
        return nil
    }


}

public enum LingroveNotebookUploadStoreError: Error, Equatable {
    case missingConfirmedBaseline, corruptBatch, receiptConflict, awaitingReceipt, cancelledUpload, rejectedIntent
}

/// One bounded control read between chunks. It borrows the restored immutable
/// envelope; cancellation must not trigger a large body parse on every poll.
public nonisolated struct LingroveNotebookUploadControl: Sendable {
    public let cancelRequested: Bool
    public let hasSettlement: Bool

    public init(cancelRequested: Bool, hasSettlement: Bool) {
        self.cancelRequested = cancelRequested
        self.hasSettlement = hasSettlement
    }
}

/// LocalDatabase owns this adapter on the same primary connection. It freezes
/// public intent once and persists complete receipts. Public writes retire only
/// their captured journals in final apply; a verified no-upload diff can retire
/// converged/private journals locally while no request exists. It never sends HTTP,
/// acknowledges held Card/review operations or mutates an existing request body.
public struct LingroveNotebookUploadStore {
    public let core: DatabaseCore

    public func next(binding: LingroveNotebookWindowBinding, transport: VocabularyWireUploadBatch.Transport = .direct,
              stagedCapability: VocabularyWireStagedCapabilities? = nil) throws -> LingroveNotebookPendingUpload? {
        // Snapshot under a read transaction, then compute/encode outside the
        // SQLite writer lock. A later local save makes the freeze CAS fail.
        let saved = try core.inReadTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            let local = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspaceID(binding))
            guard let baseline = try LingroveNotebookSyncStore(core: core).confirmedBaselineInTransaction(binding: binding, localNotebookID: local.notebookId) else {
                throw LingroveNotebookUploadStoreError.missingConfirmedBaseline
            }
            let base = baseline.shadow
            let existing = try readInTransaction(binding: binding, localNotebookID: local.notebookId, base: base)
            return (local: local, base: base, pending: existing,
                    coverage: try coverage(workspaceID: local.workspaceId, localNotebookID: local.notebookId, through: local.revision), remoteRevision: baseline.revision)
        }
        if let existing = saved.pending { return existing }
        try core.inReadTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            try LingroveNotebookConflictStore(core: core).checkRejectionInTransaction(binding: binding)
            try LingroveNotebookUploadClosureStore(core: core).checkRetryInTransaction(binding: binding, localNotebookID: saved.local.notebookId,
                journalRevision: publicJournalRevision(workspaceID: saved.local.workspaceId, localNotebookID: saved.local.notebookId))
        }
        let planned: VocabularyWireUploadBatch?
        do {
            planned = try transport == .direct
                ? VocabularyWireUploadPlanner.make(local: saved.local.document, base: saved.base, initializeEmpty: !saved.coverage.isEmpty)
                : VocabularyWireUploadPlanner.makeStaged(local: saved.local.document, base: saved.base, initializeEmpty: !saved.coverage.isEmpty)
        } catch VocabularyWireUploadError.requestTooLarge where transport == .direct && stagedCapability != nil {
            // Only a new oversized intent may choose another transport. The
            // existing-ticket return above never rewrites a frozen direct body.
            planned = try VocabularyWireUploadPlanner.makeStaged(local: saved.local.document, base: saved.base, initializeEmpty: !saved.coverage.isEmpty)
        }
        guard let batch = planned else {
            guard !saved.coverage.isEmpty else { return nil }
            try Task.checkCancellation()
            return try core.inTransaction {
                try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
                let local = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspaceID(binding))
                guard let baseline = try LingroveNotebookSyncStore(core: core).confirmedBaselineInTransaction(binding: binding, localNotebookID: local.notebookId) else {
                    throw LingroveNotebookUploadStoreError.missingConfirmedBaseline
                }
                if let existing = try readInTransaction(binding: binding, localNotebookID: local.notebookId, base: baseline.shadow) { return existing }
                guard local.notebookId == saved.local.notebookId, local.revision == saved.local.revision,
                      baseline.shadow.sequence == saved.base.sequence, baseline.revision == saved.remoteRevision,
                      try coverage(workspaceID: local.workspaceId, localNotebookID: local.notebookId, through: local.revision) == saved.coverage else {
                    throw LingroveNotebookSyncStoreError.stalePreparation
                }
                // No request was frozen and the planner found no uploadable
                // public diff. Retire only this captured local journal
                // subset; private document bytes remain and no receipt is made.
                try LingroveNotebookConflictStore(core: core).checkRejectionInTransaction(binding: binding)
            try LingroveNotebookUploadClosureStore(core: core).checkRetryInTransaction(binding: binding, localNotebookID: local.notebookId,
                    journalRevision: publicJournalRevision(workspaceID: local.workspaceId, localNotebookID: local.notebookId))
                try LingroveNotebookConflictStore(core: core).clearRejectionInTransaction(binding: binding)
                try retireCoverage(saved.coverage, workspaceID: local.workspaceId)
                try LingroveNotebookUploadClosureStore(core: core).clearRetryInTransaction(binding: binding)
                try Task.checkCancellation()
                return nil
            }
        }
        let body = try batch.encodedBody()
        let selectedTransport = batch.transport
        if selectedTransport == .staged { try stagedCapability?.validate(bodyBytes: body.count, members: batch.request.members.count) }
        let target = try encode(batch.targetEntities)
        let covered = try encode(saved.coverage)
        let staged = try selectedTransport == .staged ? VocabularyWireStagedUpload(batch: batch, frozenBody: body) : nil
        let frozen = digest(binding: binding, localNotebookID: saved.local.notebookId, revision: Int64(saved.local.revision),
            sequence: saved.base.sequence, body: body, target: target, coverage: covered, transport: selectedTransport)
        try Task.checkCancellation()
        return try core.inTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            let local = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspaceID(binding))
            guard let baseline = try LingroveNotebookSyncStore(core: core).confirmedBaselineInTransaction(binding: binding, localNotebookID: local.notebookId) else {
                throw LingroveNotebookUploadStoreError.missingConfirmedBaseline
            }
            let base = baseline.shadow
            if let existing = try readInTransaction(binding: binding, localNotebookID: local.notebookId, base: base) { return existing }
            guard local.notebookId == saved.local.notebookId, local.revision == saved.local.revision, base.sequence == saved.base.sequence, baseline.revision == saved.remoteRevision,
                  try coverage(workspaceID: local.workspaceId, localNotebookID: local.notebookId, through: local.revision) == saved.coverage else {
                throw LingroveNotebookSyncStoreError.stalePreparation
            }
            try LingroveNotebookConflictStore(core: core).checkRejectionInTransaction(binding: binding)
            try LingroveNotebookUploadClosureStore(core: core).checkRetryInTransaction(binding: binding, localNotebookID: local.notebookId,
                journalRevision: publicJournalRevision(workspaceID: local.workspaceId, localNotebookID: local.notebookId))
            guard let text = String(data: body, encoding: .utf8) else { throw LingroveNotebookUploadStoreError.corruptBatch }
            try core.execute(sql: """
                INSERT INTO notebook_upload_batches(workspace_id,local_notebook_id,owner_user_id,remote_notebook_id,replica_id,base_sequence,local_revision,request_json,target_json,coverage_json,frozen_sha256,transport_kind)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """, values: [.text(local.workspaceId), .text(local.notebookId.uuidString), .text(binding.scope.ownerUserID),
                    .text(binding.scope.notebookID.uuidString.lowercased()), .text(binding.scope.replicaID.uuidString.lowercased()),
                    .text(base.sequence.rawValue), .integer(Int64(local.revision)), .text(text), .text(target), .text(covered), .text(frozen), .text(selectedTransport.rawValue)])
            try LingroveNotebookConflictStore(core: core).clearRejectionInTransaction(binding: binding)
            try LingroveNotebookUploadTerminalStore(core: core).initializeInTransaction(workspaceID: local.workspaceId, frozenSHA256: frozen)
            if let staged { try LingroveNotebookStagedUploadStore(core: core).initializeInTransaction(upload: staged, frozenSHA256: frozen) }
            try LingroveNotebookUploadClosureStore(core: core).clearRetryInTransaction(binding: binding)
            return .init(batch: batch, body: body, receipt: nil, rejection: nil, cancelRequested: false, frozenSHA256: frozen,
                stagedUpload: staged, confirmationManifest: nil, receivedConfirmationOrdinals: [], stagedClosure: nil,
                retryIntent: staged == nil ? nil : .init(cancelRevision: 0, resumeRevision: nil), coverage: saved.coverage)
        }
    }

    public func recordReceipt(_ receipt: VocabularyWireGroupReceipt, bodySHA256: String, binding: LingroveNotebookWindowBinding) throws {
        try recordOutcome(.committed(receipt), bodySHA256: bodySHA256, binding: binding)
    }
    /// Recovery must never call next() merely to reread state: if a concurrent
    /// apply finished, next() could freeze a different group in the same run.
    public func existing(binding: LingroveNotebookWindowBinding, frozenSHA256: String) throws -> LingroveNotebookPendingUpload {
        try core.inReadTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            let local = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspaceID(binding))
            guard let base = try LingroveNotebookSyncStore(core: core).confirmedShadowInTransaction(binding: binding, localNotebookID: local.notebookId),
                  let pending = try readInTransaction(binding: binding, localNotebookID: local.notebookId, base: base), pending.frozenSHA256 == frozenSHA256 else {
                throw LingroveNotebookSyncStoreError.stalePreparation
            }
            return pending
        }
    }

    public func control(_ pending: LingroveNotebookPendingUpload, binding: LingroveNotebookWindowBinding) throws -> LingroveNotebookUploadControl {
        try core.inReadTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            guard pending.batch.scope == binding.scope, let upload = pending.stagedUpload else { throw LingroveNotebookUploadStoreError.receiptConflict }
            let rows = try core.query(sql: """
                SELECT u.frozen_sha256,t.frozen_sha256,s.frozen_sha256,c.frozen_sha256,s.descriptor_sha256,t.cancel_requested,
                  (s.manifest_json IS NOT NULL OR c.closure_json IS NOT NULL)
                FROM notebook_upload_batches u JOIN notebook_upload_terminal_state t USING(workspace_id)
                JOIN notebook_staged_uploads s USING(workspace_id) JOIN notebook_upload_transport_state c USING(workspace_id)
                WHERE u.workspace_id=? AND u.transport_kind='staged'
                """, values: [.text(workspaceID(binding))]) { statement in
                guard try (0...3).allSatisfy({ try text(statement, Int32($0)) == pending.frozenSHA256 }),
                      try text(statement, 4) == upload.descriptorSHA256, sqlite3_column_type(statement, 5) == SQLITE_INTEGER,
                      [0,1].contains(sqlite3_column_int64(statement, 5)) else { throw LingroveNotebookUploadStoreError.corruptBatch }
                return LingroveNotebookUploadControl(cancelRequested: sqlite3_column_int64(statement, 5) == 1,
                    hasSettlement: sqlite3_column_int64(statement, 6) != 0)
            }
            guard rows.count == 1 else { throw LingroveNotebookUploadStoreError.receiptConflict }
            _ = try LingroveNotebookRetryStore(core: core).readInTransaction(upload: upload, frozenSHA256: pending.frozenSHA256, cancelRequested: rows[0].cancelRequested)
            return rows[0]
        }
    }

    public func recordOutcome(_ outcome: VocabularyWireGroupOutcome, bodySHA256: String, binding: LingroveNotebookWindowBinding) throws {
        try core.inTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            let local = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspaceID(binding))
            guard let base = try LingroveNotebookSyncStore(core: core).confirmedShadowInTransaction(binding: binding, localNotebookID: local.notebookId) else { throw LingroveNotebookUploadStoreError.missingConfirmedBaseline }
            let groupID: UUID
            switch outcome {
            case let .committed(value): groupID = value.groupID
            case let .rejected(value): groupID = value.groupID
            }
            let terminal = LingroveNotebookUploadTerminalStore(core: core)
            guard try !LingroveNotebookUploadClosureStore(core: core).hasCompletedInTransaction(groupID: groupID, binding: binding) else {
                throw LingroveNotebookUploadStoreError.receiptConflict
            }
            guard try !LingroveNotebookStagedUploadStore(core: core).hasCompletedInTransaction(groupID: groupID, binding: binding) else {
                throw LingroveNotebookUploadStoreError.receiptConflict
            }
            if let done = try terminal.completedInTransaction(groupID: groupID, bodySHA256: bodySHA256, binding: binding, localNotebookID: local.notebookId) {
                guard done == outcome else { throw LingroveNotebookUploadStoreError.receiptConflict }; return
            }
            guard let pending = try readInTransaction(binding: binding, localNotebookID: local.notebookId, base: base) else { throw LingroveNotebookUploadStoreError.receiptConflict }
            guard pending.batch.transport == .direct else { throw LingroveNotebookUploadStoreError.receiptConflict }
            guard pending.bodySHA256 == bodySHA256 else { throw LingroveNotebookUploadStoreError.receiptConflict }
            try outcome.validate(for: pending.batch)
            if let prior = pending.outcome {
                guard prior == outcome else { throw LingroveNotebookUploadStoreError.receiptConflict }; return
            }
            switch outcome {
            case let .committed(receipt):
                let json = try core.encodeJsonString(value: receipt)
                let changed = try core.execute(sql: "UPDATE notebook_upload_batches SET receipt_json=?,receipt_sha256=? WHERE workspace_id=? AND frozen_sha256=? AND receipt_json IS NULL",
                    values: [.text(json), .text(sha256(Data(json.utf8))), .text(workspaceID(binding)), .text(pending.frozenSHA256)])
                guard changed == 1 else { throw LingroveNotebookUploadStoreError.receiptConflict }
            case let .rejected(rejection): try terminal.recordInTransaction(rejection, pending: pending)
            }
        }
    }

    /// Persist intent before asking the server to cancel. A timeout keeps the
    /// same group/body and this flag, so restart cannot silently resend apply.
    public func requestCancellation(groupID: UUID, bodySHA256: String, binding: LingroveNotebookWindowBinding) throws {
        try core.inTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            let local = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspaceID(binding))
            guard let base = try LingroveNotebookSyncStore(core: core).confirmedShadowInTransaction(binding: binding, localNotebookID: local.notebookId),
                  let pending = try readInTransaction(binding: binding, localNotebookID: local.notebookId, base: base),
                  pending.batch.request.groupID == groupID, pending.bodySHA256 == bodySHA256 else { throw LingroveNotebookUploadStoreError.receiptConflict }
            try LingroveNotebookUploadTerminalStore(core: core).requestCancellationInTransaction(pending)
        }
    }

    /// Borrow the caller's transaction. The base cannot advance while this
    /// group is outstanding; restore proves the frozen public diff again.
    public func readInTransaction(binding: LingroveNotebookWindowBinding, localNotebookID: UUID, base: VocabularyWireServerShadow) throws -> LingroveNotebookPendingUpload? {
        let headers = try core.query(sql: """
            SELECT local_notebook_id,owner_user_id,remote_notebook_id,replica_id,base_sequence,local_revision,request_json,target_json,coverage_json,frozen_sha256,receipt_json,receipt_sha256,transport_kind
            FROM notebook_upload_batches WHERE workspace_id=?
            """, values: [.text(workspaceID(binding))]) { statement in
            guard UUID(uuidString: try text(statement, 0)) == localNotebookID,
                  (try text(statement, 1)).utf8.elementsEqual(binding.scope.ownerUserID.utf8),
                  UUID(uuidString: try text(statement, 2)) == binding.scope.notebookID,
                  UUID(uuidString: try text(statement, 3)) == binding.scope.replicaID else { throw LingroveNotebookSyncStoreError.scopeChanged }
            let sequence = try VocabularyWireSequence(text(statement, 4)), revision = sqlite3_column_int64(statement, 5)
            guard sequence == base.sequence, sqlite3_column_type(statement, 5) == SQLITE_INTEGER, revision >= 0 else { throw LingroveNotebookUploadStoreError.corruptBatch }
            guard let transport = VocabularyWireUploadBatch.Transport(rawValue: try text(statement, 12)) else { throw LingroveNotebookUploadStoreError.corruptBatch }
            return (sequence, revision, Data(try text(statement, 6).utf8), try text(statement, 7), try text(statement, 8),
                    try text(statement, 9), try optionalText(statement, 10), try optionalText(statement, 11), transport)
        }
        guard let row = headers.first else { return nil }
        guard digest(binding: binding, localNotebookID: localNotebookID, revision: row.1, sequence: row.0, body: row.2, target: row.3, coverage: row.4, transport: row.8) == row.5 else {
            throw LingroveNotebookUploadStoreError.corruptBatch
        }
        let target = try JSONDecoder().decode([VocabularyWireEntity].self, from: Data(row.3.utf8))
        let batch = try row.8 == .direct
            ? VocabularyWireUploadPlanner.restore(body: row.2, targetEntities: target, expectedBaseSequence: row.0, base: base)
            : VocabularyWireUploadPlanner.restoreStaged(body: row.2, targetEntities: target, expectedBaseSequence: row.0, base: base)
        let staged = try row.8 == .staged ? VocabularyWireStagedUpload(batch: batch, frozenBody: row.2) : nil
        let coverage = try JSONDecoder().decode([LingroveNotebookUploadCoverage].self, from: Data(row.4.utf8))
        guard Set(coverage.map(\.operationID)).count == coverage.count,
              coverage.allSatisfy({ !$0.operationID.isEmpty && UUID(uuidString: $0.notebookID) == localNotebookID && $0.baseRevision >= 0 && $0.revision > $0.baseRevision && $0.revision <= row.1 && [0,1].contains($0.hasTemplates) }) else {
            throw LingroveNotebookUploadStoreError.corruptBatch
        }
        var receipt: VocabularyWireGroupReceipt?
        if let json = row.6 {
            guard sha256(Data(json.utf8)) == row.7 else { throw LingroveNotebookUploadStoreError.corruptBatch }
            receipt = try JSONDecoder().decode(VocabularyWireGroupReceipt.self, from: Data(json.utf8)); try receipt?.validate(for: batch)
        } else if row.7 != nil { throw LingroveNotebookUploadStoreError.corruptBatch }
        let terminal = try LingroveNotebookUploadTerminalStore(core: core).readInTransaction(workspaceID: workspaceID(binding), frozenSHA256: row.5, batch: batch)
        guard receipt == nil || terminal.rejection == nil else { throw LingroveNotebookUploadStoreError.corruptBatch }
        let progress = try LingroveNotebookStagedUploadStore(core: core).readInTransaction(upload: staged, workspaceID: workspaceID(binding), frozenSHA256: row.5)
        let closure: VocabularyWireStagedClosure?
        let retryIntent: LingroveNotebookRetryState?
        if let staged {
            closure = try LingroveNotebookUploadClosureStore(core: core).readInTransaction(upload: staged, frozenSHA256: row.5)
            retryIntent = try LingroveNotebookRetryStore(core: core).readInTransaction(upload: staged, frozenSHA256: row.5, cancelRequested: terminal.cancelRequested)
        } else { closure = nil; retryIntent = nil }
        guard closure == nil || (progress.manifest == nil && progress.ordinals.isEmpty && progress.outcome == nil && receipt == nil && terminal.rejection == nil) else {
            throw LingroveNotebookUploadStoreError.corruptBatch
        }
        var rejection = terminal.rejection
        if staged != nil {
            guard receipt == nil, rejection == nil else { throw LingroveNotebookUploadStoreError.corruptBatch }
            switch progress.outcome {
            case let .committed(value): receipt = value
            case let .rejected(value): rejection = value
            case nil: break
            }
        }
        return .init(batch: batch, body: row.2, receipt: receipt, rejection: rejection, cancelRequested: terminal.cancelRequested, frozenSHA256: row.5,
            stagedUpload: staged, confirmationManifest: progress.manifest, receivedConfirmationOrdinals: progress.ordinals, stagedClosure: closure, retryIntent: retryIntent, coverage: coverage)
    }

    public func isFinishedInTransaction(_ pending: LingroveNotebookPendingUpload, localNotebookID: UUID, binding: LingroveNotebookWindowBinding) throws -> Bool {
        if pending.stagedClosure != nil {
            return try LingroveNotebookUploadClosureStore(core: core).isFinishedInTransaction(pending, localNotebookID: localNotebookID, binding: binding)
        }
        guard let known = pending.outcome else { return false }
        if pending.batch.transport == .staged {
            return try LingroveNotebookStagedUploadStore(core: core).isFinishedInTransaction(pending, localNotebookID: localNotebookID, binding: binding)
        }
        guard let done = try LingroveNotebookUploadTerminalStore(core: core).completedInTransaction(groupID: pending.batch.request.groupID,
            bodySHA256: pending.bodySHA256, binding: binding, localNotebookID: localNotebookID) else { return false }
        guard done == known else { throw LingroveNotebookUploadStoreError.receiptConflict }
        return true
    }

    /// Called only after a matching receipt's covering window has rebased the
    /// document in this same transaction. Newer journal headers and all held
    /// Card/review operations remain outside this exact retirement subset.
    public func finishInTransaction(_ pending: LingroveNotebookPendingUpload, localNotebookID: UUID) throws {
        if pending.stagedClosure != nil {
            try LingroveNotebookUploadClosureStore(core: core).finishInTransaction(pending, localNotebookID: localNotebookID,
                blockedJournalRevision: pending.coverage.map(\.revision).max() ?? 0)
            return
        }
        if pending.batch.transport == .staged {
            guard pending.outcome != nil else { throw LingroveNotebookUploadStoreError.awaitingReceipt }
            if pending.receipt != nil { try retireCoverage(pending.coverage, workspaceID: pending.batch.scope.workspaceID.uuidString.lowercased()) }
            try LingroveNotebookStagedUploadStore(core: core).finishInTransaction(pending, localNotebookID: localNotebookID)
            return
        }
        if pending.rejection != nil {
            try LingroveNotebookUploadTerminalStore(core: core).finishRejectedInTransaction(pending, localNotebookID: localNotebookID)
            return
        }
        guard let receipt = pending.receipt else { throw LingroveNotebookUploadStoreError.awaitingReceipt }
        let scope = pending.batch.scope, workspace = scope.workspaceID.uuidString.lowercased()
        try retireCoverage(pending.coverage, workspaceID: workspace)
        try core.execute(sql: """
            INSERT INTO notebook_upload_receipts(workspace_id,group_id,local_notebook_id,owner_user_id,remote_notebook_id,replica_id,body_sha256,receipt_json,created_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, values: [.text(workspace), .text(receipt.groupID.uuidString.lowercased()), .text(localNotebookID.uuidString),
                .text(scope.ownerUserID), .text(scope.notebookID.uuidString.lowercased()), .text(scope.replicaID.uuidString.lowercased()),
                .text(pending.bodySHA256), .text(try core.encodeJsonString(value: receipt)), .text(nowIsoTimestamp())])
        let removed = try core.execute(sql: "DELETE FROM notebook_upload_batches WHERE workspace_id=? AND frozen_sha256=?",
            values: [.text(workspace), .text(pending.frozenSHA256)])
        guard removed == 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
    }

    private func retireCoverage(_ coverage: [LingroveNotebookUploadCoverage], workspaceID: String) throws {
        for item in coverage {
            let deleted = try core.execute(sql: """
                DELETE FROM notebook_pending_transactions WHERE operation_id=? AND workspace_id=? AND notebook_id=?
                  AND base_revision=? AND revision=? AND has_templates=? AND created_at=?
                """, values: [.text(item.operationID), .text(workspaceID), .text(item.notebookID),
                    .integer(item.baseRevision), .integer(item.revision), .integer(item.hasTemplates), .text(item.createdAt)])
            guard deleted == 1 else { throw LingroveNotebookUploadStoreError.corruptBatch }
        }
    }

    private func coverage(workspaceID: String, localNotebookID: UUID, through revision: UInt64) throws -> [LingroveNotebookUploadCoverage] {
        try core.query(sql: "SELECT operation_id,base_revision,revision,has_templates,created_at,notebook_id FROM notebook_pending_transactions WHERE workspace_id=? AND revision<=? ORDER BY revision,operation_id",
            values: [.text(workspaceID), .integer(Int64(revision))]) { statement in
            guard UUID(uuidString: try text(statement, 5)) == localNotebookID,
                  [1,2,3].allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }) else { throw LingroveNotebookUploadStoreError.corruptBatch }
            let item = LingroveNotebookUploadCoverage(operationID: try text(statement, 0), notebookID: try text(statement, 5),
                baseRevision: sqlite3_column_int64(statement, 1), revision: sqlite3_column_int64(statement, 2),
                hasTemplates: sqlite3_column_int64(statement, 3), createdAt: try text(statement, 4))
            guard !item.operationID.isEmpty, item.baseRevision >= 0, item.revision > item.baseRevision,
                  item.revision <= Int64(revision), [0,1].contains(item.hasTemplates) else { throw LingroveNotebookUploadStoreError.corruptBatch }
            return item
        }
    }
    private func publicJournalRevision(workspaceID: String, localNotebookID: UUID) throws -> Int64 {
        Int64(try core.scalarInt(sql: "SELECT COALESCE(MAX(revision),0) FROM notebook_pending_transactions WHERE workspace_id=? AND notebook_id=? AND has_public_change=1",
            values: [.text(workspaceID), .text(localNotebookID.uuidString)]))
    }
    private func digest(binding: LingroveNotebookWindowBinding, localNotebookID: UUID, revision: Int64, sequence: VocabularyWireSequence,
                        body: Data, target: String, coverage: String, transport: VocabularyWireUploadBatch.Transport) -> String {
        var hash = SHA256()
        // Keep schema 31/32 direct digests byte-for-byte stable. A staged batch
        // has a distinct domain so changing only transport_kind cannot upgrade it.
        let parts = [Data((transport == .direct ? "lingrove-local-upload:1" : "lingrove-local-staged-upload:1").utf8), Data(binding.scope.ownerUserID.utf8), Data(workspaceID(binding).utf8),
            Data(localNotebookID.uuidString.lowercased().utf8), Data(binding.scope.notebookID.uuidString.lowercased().utf8),
            Data(binding.scope.replicaID.uuidString.lowercased().utf8), Data(String(revision).utf8), Data(sequence.rawValue.utf8), body, Data(target.utf8), Data(coverage.utf8)]
        for part in parts { hash.update(data: Data("\(part.count)\n".utf8)); hash.update(data: part); hash.update(data: Data("\n".utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func workspaceID(_ binding: LingroveNotebookWindowBinding) -> String { binding.scope.workspaceID.uuidString.lowercased() }
    private func encode<T: Encodable>(_ value: T) throws -> String {
        // These calls run outside Core's transaction. Each operation owns its
        // encoder instead of sharing the connection's mutable encoder object.
        guard let json = String(data: try JSONEncoder().encode(value), encoding: .utf8) else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return json
    }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func text(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, index),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), encoding: .utf8) else { throw LingroveNotebookUploadStoreError.corruptBatch }
        return value
    }
    private func optionalText(_ statement: OpaquePointer, _ index: Int32) throws -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : try text(statement, index)
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
