import CryptoKit
import Foundation
import LingroveNotebook
import LingroveNotebookSync
import SQLite3

/// A prepared candidate owns immutable values, not the connection. Only this
/// file can create one. A later commit compares both local and remote revisions
/// so a UI save or a concurrent pull cannot be overwritten by stale preparation.
public nonisolated struct LingroveNotebookApplyPlan: Sendable {
    /// The media coordinator sees references only after the ordinary complete
    /// graph/rebase checks, and cannot mutate or partially commit this plan.
    public var imageReferences: [VocabularyImageReference] { VocabularyDocumentValidation.imageReferences(result.materialization.document) }
    fileprivate let binding: LingroveNotebookWindowBinding
    fileprivate let manifest: VocabularyWireWindowManifest
    fileprivate let baseline: LingroveNotebookSnapshot
    fileprivate let remoteRevision: Int64?
    fileprivate let result: VocabularyWireRebaseResult
    fileprivate let privateJSON: String
    fileprivate let stagedImages: Set<VocabularyImageReference>
    fileprivate let pendingUpload: LingroveNotebookPendingUpload?
    fileprivate let resolutionToken: String
}

public enum LingroveNotebookSyncStoreError: Error, Equatable {
    case scopeChanged, corruptState, stalePreparation
}

/// LocalDatabase owns this adapter on its existing SQLite connection. Prepare
/// snapshots the current document and confirmed shadow, then computes the pure
/// overlay without holding the writer transaction. Commit atomically writes the
/// merged document, shadow, private remainder and cursor. Ordinary pulls never
/// acknowledge uploads; a receipt-covered apply retires only its frozen corpus
/// journal subset. Held Card/review operations remain owned by their own lane.
public struct LingroveNotebookSyncStore {
    public let core: DatabaseCore

    private struct State {
        let localNotebookID: UUID
        let revision: Int64
        let lastManifestSHA256: String
        let shadow: VocabularyWireServerShadow
        let privateState: VocabularyWirePrivateState
    }
    private typealias EncodedRecord = (record: VocabularyWireCorpusRecord, json: String)

    public func prepare(_ window: VocabularyWireVerifiedWindow, binding: LingroveNotebookWindowBinding,
                 images: [String: Data], now: Date) throws -> LingroveNotebookApplyPlan {
        try window.manifest.validate(expecting: binding.scope, now: now)
        let saved = try core.inReadTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            let snapshot = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspaceID(binding))
            let state = try readState(binding: binding, localNotebookID: snapshot.notebookId)
            let pending = try LingroveNotebookUploadStore(core: core).readInTransaction(binding: binding,
                localNotebookID: snapshot.notebookId, base: state?.shadow ?? .empty(scope: binding.scope))
            let choices = try LingroveNotebookConflictStore(core: core).selectionsInTransaction(binding: binding)
            let token = try LingroveNotebookConflictStore(core: core).resolutionTokenInTransaction(binding: binding)
            let handoff = try LingroveNotebookAccountStore(core: core).privateRemainderInTransaction(workspaceID: snapshot.workspaceId,
                localNotebookID: snapshot.notebookId, remoteNotebookID: binding.scope.notebookID)
            return (snapshot, state, pending, choices, token, handoff)
        }
        let base = saved.1?.shadow ?? .empty(scope: binding.scope)
        let acknowledgement: VocabularyWireUploadAcknowledgement?
        if let pending = saved.2 {
            if let receipt = pending.receipt { acknowledgement = try .init(batch: pending.batch, receipt: receipt) }
            else if pending.rejection != nil || pending.stagedClosure != nil { acknowledgement = nil }
            else { throw LingroveNotebookUploadStoreError.awaitingReceipt }
        } else { acknowledgement = nil }
        try Task.checkCancellation()
        let localDocument: VocabularyDocument
        if saved.1 == nil, window.manifest.initialized,
           !saved.0.document.catalog.isEmpty || !saved.0.document.semantics.nodes.isEmpty {
            let remote = try base.applying(window, now: now)
            let combine = try LingroveNotebookAccountStore(core: core).firstDecision(local: saved.0, binding: binding,
                remoteEntries: remote.records.filter { !$0.deleted && $0.entity.entityType == .entry }.count)
            localDocument = combine ? saved.0.document : VocabularyDocument()
        } else { localDocument = saved.0.document }
        let privateState = LingroveNotebookAccountStore.combinePrivate(saved.1?.privateState, saved.5, notebookID: binding.scope.notebookID)
        let result: VocabularyWireRebaseResult
        do {
            do {
                result = try VocabularyWireRebase.prepare(local: localDocument, base: base, window: window,
                    retaining: privateState, acknowledging: acknowledgement, resolving: saved.3, now: now)
            } catch VocabularyWireRebaseError.staleResolution {
                // A stale choice grants no authority over a new value. If the
                // ordinary merge now converges, it needs no choice at all.
                result = try VocabularyWireRebase.prepare(local: localDocument, base: base, window: window,
                    retaining: privateState, acknowledging: acknowledgement, now: now)
            }
        } catch {
            // Stale explicit choices must be reviewed again against current
            // values. Recomputing without them only discovers conflicts; it
            // cannot commit or authorize a replacement choice.
            let failure = error
            if case let VocabularyWireRebaseError.conflicts(conflicts) = failure {
                let remote = try base.applying(window, now: now)
                let projection = try VocabularyWireProjectionCodec.project(saved.0.document, notebookID: binding.scope.notebookID)
                let local = Dictionary(uniqueKeysWithValues: projection.entities.map { ($0.entityType.rawValue + ":" + $0.entityID, $0) })
                let records = Dictionary(uniqueKeysWithValues: remote.records.map { ($0.entity.entityType.rawValue + ":" + $0.entity.entityID, $0) })
                let candidates = conflicts.map { conflict in
                    let key = conflict.entityType.rawValue + ":" + conflict.entityID
                    let record = records[key]
                    return VocabularyWireConflictSelection(conflict: conflict, local: local[key], remote: record?.deleted == false ? record?.entity : nil,
                        remoteVersion: record?.version, choice: .remote)
                }
                try core.inTransaction {
                    try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
                    let current = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspaceID(binding))
                    let state = try readState(binding: binding, localNotebookID: current.notebookId)
                    let pending = try LingroveNotebookUploadStore(core: core).readInTransaction(binding: binding,
                        localNotebookID: current.notebookId, base: state?.shadow ?? .empty(scope: binding.scope))
                    guard current.revision == saved.0.revision, current.notebookId == saved.0.notebookId,
                          state?.revision == saved.1?.revision, pending?.frozenSHA256 == saved.2?.frozenSHA256,
                          pending?.outcome == saved.2?.outcome else { throw LingroveNotebookSyncStoreError.stalePreparation }
                    try LingroveNotebookConflictStore(core: core).recordInTransaction(candidates, local: current, binding: binding)
                }
            }
            throw failure
        }
        let staged = try LingroveNotebookMediaStore(core: core).stageSuppliedImages(document: result.materialization.document, supplied: images)
        return .init(binding: binding, manifest: window.manifest, baseline: saved.0, remoteRevision: saved.1?.revision,
            result: result, privateJSON: try LingroveNotebookPrivateStateCodec.encode(result.materialization.unattachedPrivateState),
            stagedImages: staged, pendingUpload: saved.2, resolutionToken: saved.4)
    }

    public func commit(_ plan: LingroveNotebookApplyPlan, now: Date) throws -> LingroveNotebookSnapshot {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let started = clock.now
        func leaseTime() -> Date {
            let elapsed = started.duration(to: clock.now).components
            return now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        }
        return try core.inTransaction {
            let binding = plan.binding
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            try plan.manifest.validate(expecting: binding.scope, now: leaseTime())
            let notebook = LingroveNotebookStore(core: core)
            let current = try notebook.readSnapshot(workspaceId: workspaceID(binding))
            let state = try readState(binding: binding, localNotebookID: current.notebookId)
            // Exact replays return the current local value, including edits
            // made after the first commit. They never replay an old candidate.
            let uploads = LingroveNotebookUploadStore(core: core)
            // A negative outcome can arrive after this same window was applied.
            // Its first settlement must still retire the rejected frozen body;
            // later replays (including after a new batch) return current edits.
            if state?.lastManifestSHA256 == plan.manifest.manifestSHA256 {
                let finished: Bool
                if let pending = plan.pendingUpload {
                    finished = try uploads.isFinishedInTransaction(pending, localNotebookID: current.notebookId, binding: binding)
                } else { finished = true }
                if finished {
                    try plan.manifest.validate(expecting: binding.scope, now: leaseTime())
                    return current
                }
            }
            let pending = try uploads.readInTransaction(binding: binding, localNotebookID: current.notebookId,
                base: state?.shadow ?? .empty(scope: binding.scope))
            guard current.notebookId == plan.baseline.notebookId, current.revision == plan.baseline.revision,
                  state?.revision == plan.remoteRevision,
                  pending?.frozenSHA256 == plan.pendingUpload?.frozenSHA256, pending?.outcome == plan.pendingUpload?.outcome,
                  pending?.stagedClosure == plan.pendingUpload?.stagedClosure,
                  pending?.cancelRequested == plan.pendingUpload?.cancelRequested,
                  pending?.retryIntent == plan.pendingUpload?.retryIntent,
                  try LingroveNotebookConflictStore(core: core).resolutionTokenInTransaction(binding: binding) == plan.resolutionToken,
                  current.revision < UInt64(Int64.max), (state?.revision ?? 0) < Int64.max else {
                throw LingroveNotebookSyncStoreError.stalePreparation
            }
            try Task.checkCancellation()
            let document = plan.result.materialization.document
            try VocabularyDocumentValidation.validate(document)
            try LingroveNotebookMediaStore(core: core).registerImages(document: document, previous: current.document,
                staged: plan.stagedImages, workspaceId: current.workspaceId)
            // Swift equality ignores Unicode normalization, while encoding a
            // private enum-key dictionary can change its order on every read.
            // Compare domain values plus literal PUBLIC fields before touching
            // rows. Remote data has no authority over device-private tool text.
            let documentChanged = try hasDocumentChanges(document, from: current.document, notebookID: binding.scope.notebookID)
            if documentChanged {
                _ = try notebook.replaceRows(document: document, previous: current.document, workspaceId: current.workspaceId,
                                             preservingLiteralPayloads: true)
            }
            let next = documentChanged ? current.revision + 1 : current.revision
            if documentChanged {
                let changed = try core.execute(sql: """
                    UPDATE notebook_state SET revision=?,has_templates=?,updated_at=?
                    WHERE workspace_id=? AND notebook_id=? AND revision=?
                    """, values: [.integer(Int64(next)), .integer(document.reviewTemplates == nil ? 0 : 1), .text(nowIsoTimestamp()),
                        .text(current.workspaceId), .text(current.notebookId.uuidString), .integer(Int64(current.revision))])
                guard changed == 1 else { throw LingroveNotebookSyncStoreError.stalePreparation }
            }
            if documentChanged {
                try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(.init(workspaceId: current.workspaceId,
                    notebookId: current.notebookId, revision: next, document: document, generation: current.generation))
            }
            try writeState(plan, revision: (state?.revision ?? 0) + 1)
            try core.execute(sql: "DELETE FROM notebook_account_private_remainders WHERE workspace_id=?", values: [.text(current.workspaceId)])
            if let rejection = pending?.rejection {
                try LingroveNotebookConflictStore(core: core).recordRejectionInTransaction(rejection, binding: binding)
            }
            if let pending { try uploads.finishInTransaction(pending, localNotebookID: current.notebookId) }
            try LingroveNotebookConflictStore(core: core).clearInTransaction(binding: binding)
            try core.execute(sql: "UPDATE notebook_first_connections SET completed=1 WHERE workspace_id=? AND authorized_generation=? AND decision<>'pending'",
                values: [.text(current.workspaceId), .text(binding.generation)])
            try Task.checkCancellation()
            // Waiting for SQLite or completing a large write consumes the same
            // fixed lease. A transaction that crossed expiry must roll back all
            // earlier document/media/shadow changes before COMMIT is attempted.
            try plan.manifest.validate(expecting: binding.scope, now: leaseTime())
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            return .init(workspaceId: current.workspaceId, notebookId: current.notebookId, revision: next, document: document, generation: current.generation)
        }
    }

    private func hasDocumentChanges(_ document: VocabularyDocument, from current: VocabularyDocument, notebookID: UUID) throws -> Bool {
        guard document == current else { return true }
        // The public projection uses string-key objects for maps and a defined
        // order for sets. Literal wire equality therefore detects NFC/NFD edits
        // without treating a private dictionary's JSON iteration order as data.
        func fields(_ value: VocabularyDocument) throws -> [String: VocabularyWireJSON] {
            let entities = try VocabularyWireProjectionCodec.project(value, notebookID: notebookID).entities
            return Dictionary(uniqueKeysWithValues: entities.map { ($0.entityType.rawValue + ":" + $0.entityID, .object($0.fields)) })
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(VocabularyWireJSON.object(fields(document))) != encoder.encode(VocabularyWireJSON.object(fields(current)))
    }

    /// Used by upload planning to derive current public intent against
    /// a confirmed baseline. It grants no authority to acknowledge old journals.
    public func confirmedShadow(binding: LingroveNotebookWindowBinding) throws -> VocabularyWireServerShadow? {
        try core.inReadTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            let local = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspaceID(binding))
            return try readState(binding: binding, localNotebookID: local.notebookId)?.shadow
        }
    }
    /// Compound upload snapshots borrow the same transaction without exposing
    /// the host-private remainder or opening another SQLite transaction.
    public func confirmedShadowInTransaction(binding: LingroveNotebookWindowBinding, localNotebookID: UUID) throws -> VocabularyWireServerShadow? {
        try readState(binding: binding, localNotebookID: localNotebookID)?.shadow
    }
    /// Upload preparation also fences metadata-only applies whose public cursor
    /// and UI document revision stay unchanged. The revision is host-local CAS
    /// state, never a server version or an acknowledgement.
    public func confirmedBaselineInTransaction(binding: LingroveNotebookWindowBinding, localNotebookID: UUID) throws -> (shadow: VocabularyWireServerShadow, revision: Int64)? {
        guard let state = try readState(binding: binding, localNotebookID: localNotebookID) else { return nil }
        return (state.shadow, state.revision)
    }

    private func readState(binding: LingroveNotebookWindowBinding, localNotebookID: UUID) throws -> State? {
        let scope = binding.scope
        let rows = try core.query(sql: """
            SELECT local_notebook_id,owner_user_id,remote_notebook_id,replica_id,sequence,initialized,revision,last_manifest_sha256,private_state_json,record_count,state_sha256
            FROM notebook_remote_state WHERE workspace_id=?
            """, values: [.text(workspaceID(binding))]) { statement in
            guard UUID(uuidString: try text(statement, 0)) == localNotebookID,
                  (try text(statement, 1)).utf8.elementsEqual(scope.ownerUserID.utf8),
                  UUID(uuidString: try text(statement, 2)) == scope.notebookID,
                  UUID(uuidString: try text(statement, 3)) == scope.replicaID else { throw LingroveNotebookSyncStoreError.scopeChanged }
            let initialized = sqlite3_column_int64(statement, 5), revision = sqlite3_column_int64(statement, 6)
            guard sqlite3_column_type(statement, 5) == SQLITE_INTEGER, [0,1].contains(initialized),
                  sqlite3_column_type(statement, 6) == SQLITE_INTEGER, revision > 0 else { throw LingroveNotebookSyncStoreError.corruptState }
            let sequence = try VocabularyWireSequence(text(statement, 4))
            let sha = try text(statement, 7)
            guard sha.utf8.count == 64, sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw LingroveNotebookSyncStoreError.corruptState }
            let count = sqlite3_column_int64(statement, 9)
            guard sqlite3_column_type(statement, 9) == SQLITE_INTEGER, count >= 0 else { throw LingroveNotebookSyncStoreError.corruptState }
            return (sequence: sequence, initialized: initialized == 1, revision: revision, manifest: sha,
                    privateJSON: try text(statement, 8), recordCount: count, digest: try text(statement, 10))
        }
        guard let header = rows.first else { return nil }
        let records: [EncodedRecord] = try core.query(sql: "SELECT entity_type,entity_id,record_json FROM notebook_remote_records WHERE workspace_id=? ORDER BY entity_type,entity_id",
            values: [.text(workspaceID(binding))]) { statement in
            let json = try text(statement, 2)
            let record = try JSONDecoder().decode(VocabularyWireCorpusRecord.self, from: Data(json.utf8))
            guard record.entity.entityType.rawValue == (try text(statement, 0)), record.entity.entityID == (try text(statement, 1)) else { throw LingroveNotebookSyncStoreError.corruptState }
            return (record, json)
        }
        guard Int64(records.count) == header.recordCount,
              stateDigest(scope: scope, localNotebookID: localNotebookID, sequence: header.sequence, initialized: header.initialized,
                revision: header.revision, manifest: header.manifest, privateJSON: header.privateJSON, records: records) == header.digest else {
            throw LingroveNotebookSyncStoreError.corruptState
        }
        let shadow = try VocabularyWireServerShadow(scope: scope, sequence: header.sequence, initialized: header.initialized, records: records.map(\.record))
        let privateState = try LingroveNotebookPrivateStateCodec.decode(header.privateJSON, notebookID: scope.notebookID)
        return .init(localNotebookID: localNotebookID, revision: header.revision, lastManifestSHA256: header.manifest, shadow: shadow, privateState: privateState)
    }

    private func writeState(_ plan: LingroveNotebookApplyPlan, revision: Int64) throws {
        let scope = plan.binding.scope, shadow = plan.result.shadow
        let records: [EncodedRecord] = try shadow.records.map { ($0, try core.encodeJsonString(value: $0)) }
        let digest = stateDigest(scope: scope, localNotebookID: plan.baseline.notebookId, sequence: shadow.sequence,
            initialized: shadow.initialized, revision: revision, manifest: plan.manifest.manifestSHA256, privateJSON: plan.privateJSON, records: records)
        try core.execute(sql: """
            INSERT INTO notebook_remote_state(workspace_id,local_notebook_id,owner_user_id,remote_notebook_id,replica_id,sequence,initialized,revision,last_manifest_sha256,private_state_json,record_count,state_sha256)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(workspace_id) DO UPDATE SET
              sequence=excluded.sequence,initialized=excluded.initialized,revision=excluded.revision,
              last_manifest_sha256=excluded.last_manifest_sha256,private_state_json=excluded.private_state_json,
              record_count=excluded.record_count,state_sha256=excluded.state_sha256
            """, values: [.text(workspaceID(plan.binding)), .text(plan.baseline.notebookId.uuidString), .text(scope.ownerUserID),
                .text(scope.notebookID.uuidString.lowercased()), .text(scope.replicaID.uuidString.lowercased()), .text(shadow.sequence.rawValue),
                .integer(shadow.initialized ? 1 : 0), .integer(revision), .text(plan.manifest.manifestSHA256), .text(plan.privateJSON),
                .integer(Int64(records.count)), .text(digest)])
        // No historical row is dropped: the confirmed snapshot includes retained
        // tombstones. The shadow verifier has already rejected identity revival.
        for encoded in records {
            let record = encoded.record
            try core.execute(sql: """
                INSERT INTO notebook_remote_records(workspace_id,entity_type,entity_id,record_json) VALUES(?,?,?,?)
                ON CONFLICT(workspace_id,entity_type,entity_id) DO UPDATE SET record_json=excluded.record_json
                """, values: [.text(workspaceID(plan.binding)), .text(record.entity.entityType.rawValue),
                    .text(record.entity.entityID), .text(encoded.json)])
        }
    }
    /// Local framing is independent of network JSON canonicalization. Count and
    /// byte digest detect a missing standalone row or changed cursor/private
    /// remainder that could still form a superficially valid domain graph.
    private func stateDigest(scope: VocabularyWireWindowScope, localNotebookID: UUID, sequence: VocabularyWireSequence,
                             initialized: Bool, revision: Int64, manifest: String, privateJSON: String, records: [EncodedRecord]) -> String {
        var hash = SHA256()
        let owner = Data(scope.ownerUserID.utf8).base64EncodedString()
        let lines = ["lingrove-local-shadow:1", localNotebookID.uuidString.lowercased(), owner,
            scope.workspaceID.uuidString.lowercased(), scope.notebookID.uuidString.lowercased(), scope.replicaID.uuidString.lowercased(),
            sequence.rawValue, initialized ? "1" : "0", String(revision), manifest, String(records.count), String(privateJSON.utf8.count), ""]
        hash.update(data: Data(lines.joined(separator: "\n").utf8)); hash.update(data: Data(privateJSON.utf8)); hash.update(data: Data("\n".utf8))
        for value in records.sorted(by: { a, b in
            (a.record.entity.entityType.rawValue + ":" + a.record.entity.entityID) < (b.record.entity.entityType.rawValue + ":" + b.record.entity.entityID)
        }) {
            hash.update(data: Data("\(value.record.entity.entityType.rawValue):\(value.record.entity.entityID):\(value.json.utf8.count)\n".utf8))
            hash.update(data: Data(value.json.utf8)); hash.update(data: Data("\n".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func workspaceID(_ binding: LingroveNotebookWindowBinding) -> String { binding.scope.workspaceID.uuidString.lowercased() }
    /// Copy SQLite-owned UTF-8 before finalizing; corrupt bytes are a failure,
    /// never a display replacement or a silently reset remote baseline.
    private func text(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, index),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), encoding: .utf8) else {
            throw LingroveNotebookSyncStoreError.corruptState
        }
        return value
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
