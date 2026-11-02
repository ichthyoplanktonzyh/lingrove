import Foundation
import LingroveNotebook
import SQLite3

/// Borrows LocalDatabase's connection. Synchronous transactions are the queue's
/// atomic boundary; no task, URLSession or mutable connection escapes a method.
/// Each completion compares its attempt/revision and captured account lifetime.
public struct LingroveNotebookMediaQueueStore {
    public let core: DatabaseCore
    public static let processID = UUID().uuidString
    private static let columns = "job_id,digest,width,height,byte_count,direction,state,remote_asset_id,attempts,revision,attempt_id"

    public func enqueue(_ references: [VocabularyImageReference], direction: LingroveNotebookMediaDirection,
                 consumer: String, binding: LingroveNotebookWindowBinding) throws -> [LingroveNotebookMediaJob] {
        guard references.count <= 100_000, consumer.utf8.count <= 200 else { throw VocabularyError.invalidContent }
        return try core.inTransaction {
            try check(binding)
            try replacePins(references, workspaceID: workspace(binding), consumer: consumer)
            return try Set(references).sorted { $0.digest < $1.digest }.map { reference in
                guard VocabularyContentPolicy.valid(reference) else { throw VocabularyError.invalidContent }
                try core.execute(sql: """
                    INSERT INTO notebook_media_jobs(job_id,workspace_id,owner_user_id,notebook_id,replica_id,binding_generation,
                      digest,width,height,byte_count,direction,state) VALUES(?,?,?,?,?,?,?,?,?,?,?,'queued')
                    ON CONFLICT(workspace_id,owner_user_id,notebook_id,digest,direction) DO NOTHING
                    """, values: [.text(UUID().uuidString)] + scope(binding) + [.text(binding.scope.replicaID.uuidString.lowercased()),
                        .text(binding.generation), .text(reference.digest), .integer(Int64(reference.width)), .integer(Int64(reference.height)),
                        .integer(Int64(reference.byteCount)), .text(direction.rawValue)])
                guard let job = try core.query(sql: "SELECT \(Self.columns) FROM notebook_media_jobs WHERE workspace_id=? AND owner_user_id=? AND notebook_id=? AND digest=? AND direction=?",
                    values: scope(binding) + [.text(reference.digest), .text(direction.rawValue)], map: map).first,
                      job.reference == reference else { throw VocabularyError.invalidContent }
                // A reconnected account can resume its same durable intent, but
                // an old generation's active HTTP attempt cannot complete it.
                try core.execute(sql: """
                    UPDATE notebook_media_jobs SET binding_generation=?,replica_id=?,
                      state=CASE WHEN state='transferring' THEN 'queued' ELSE state END,
                      attempt_id=NULL,process_id=NULL,lease_until=NULL,revision=revision+1
                    WHERE job_id=? AND binding_generation<>?
                    """, values: [.text(binding.generation), .text(binding.scope.replicaID.uuidString.lowercased()), .text(job.id), .text(binding.generation)])
                return try load(job.id, binding: binding)
            }
        }
    }

    public func claim(_ id: String, binding: LingroveNotebookWindowBinding, recheckReady: Bool = false,
               now: Date = Date(), processID: String = Self.processID) throws -> LingroveNotebookMediaJob {
        try core.inTransaction {
            try check(binding)
            let job = try load(id, binding: binding)
            if job.state == .cancelled { throw LingroveNotebookMediaError.incomplete(.cancelled) }
            if job.state == .ready && !recheckReady { return job }
            let timing = try core.query(sql: "SELECT process_id,lease_until,next_attempt_at FROM notebook_media_jobs WHERE job_id=?", values: [.text(id)]) { statement in
                (DatabaseCore.columnOptionalText(statement: statement, index: 0), sqlite3_column_double(statement, 1), sqlite3_column_double(statement, 2))
            }.first!
            if job.state == .transferring, timing.0 == processID, timing.1 > now.timeIntervalSince1970 { throw LingroveNotebookMediaError.busy }
            if job.state != .transferring, job.state != .ready, timing.2 > now.timeIntervalSince1970 {
                throw LingroveNotebookMediaError.incomplete(job.state)
            }
            guard job.revision < Int64.max, job.attempts < 1_000_000 else { throw VocabularyError.invalidContent }
            try core.execute(sql: """
                UPDATE notebook_media_jobs SET state='transferring',attempt_id=?,process_id=?,lease_until=?,next_attempt_at=NULL,
                  attempts=attempts+1,revision=revision+1,error_code=NULL WHERE job_id=?
                """, values: [.text(UUID().uuidString), .text(processID), .real(now.timeIntervalSince1970 + 60), .text(id)])
            return try load(id, binding: binding)
        }
    }

    public func checkAttempt(_ job: LingroveNotebookMediaJob, binding: LingroveNotebookWindowBinding) throws {
        try check(binding)
        let current = try load(job.id, binding: binding)
        guard current.revision == job.revision, current.attemptID == job.attemptID, current.state == .transferring else {
            if current.state == .cancelled { throw LingroveNotebookMediaError.incomplete(.cancelled) }
            throw LingroveNotebookMediaError.staleAttempt
        }
    }

    public func complete(_ job: LingroveNotebookMediaJob, remoteAssetID: UUID?, binding: LingroveNotebookWindowBinding,
                  received: (VocabularyImageReference, Data)? = nil) throws {
        if let received {
            guard received.0 == job.reference else { throw VocabularyError.invalidContent }
            try LingroveNotebookMediaStore(core: core).stageImage(received.1, reference: received.0)
        }
        try core.inTransaction {
            try checkAttempt(job, binding: binding)
            if received != nil { try LingroveNotebookMediaStore(core: core).registerImage(job.reference, workspaceId: workspace(binding)) }
            // A registry/cache row alone does not establish that the file is
            // complete. Revalidate bytes before publishing the ready state.
            _ = try LingroveNotebookMediaStore(core: core).ownedImage(job.reference, workspaceId: workspace(binding))
            try core.execute(sql: """
                UPDATE notebook_media_jobs SET state='ready',remote_asset_id=COALESCE(?,remote_asset_id),attempt_id=NULL,
                  process_id=NULL,lease_until=NULL,next_attempt_at=NULL,error_code=NULL WHERE job_id=?
                """, values: [remoteAssetID.map { .text($0.uuidString.lowercased()) } ?? .null, .text(job.id)])
        }
    }

    public func available(_ job: LingroveNotebookMediaJob, binding: LingroveNotebookWindowBinding) throws {
        try core.inTransaction {
            try check(binding)
            let current = try load(job.id, binding: binding)
            guard current.revision == job.revision else { throw LingroveNotebookMediaError.staleAttempt }
            guard current.state != .cancelled else { return }
            _ = try LingroveNotebookMediaStore(core: core).ownedImage(job.reference, workspaceId: workspace(binding))
            try core.execute(sql: "UPDATE notebook_media_jobs SET state='ready',attempt_id=NULL,process_id=NULL,lease_until=NULL,next_attempt_at=NULL,error_code=NULL WHERE job_id=?",
                values: [.text(job.id)])
        }
    }

    public func fail(_ job: LingroveNotebookMediaJob, state: LingroveNotebookMediaState, binding: LingroveNotebookWindowBinding, now: Date = Date()) throws {
        guard [.queued, .missing, .failed].contains(state) else { throw VocabularyError.invalidContent }
        try core.inTransaction {
            try checkAttempt(job, binding: binding)
            let delay = min(300.0, pow(2, Double(min(job.attempts, 8))))
            try core.execute(sql: "UPDATE notebook_media_jobs SET state=?,attempt_id=NULL,process_id=NULL,lease_until=NULL,next_attempt_at=?,error_code=? WHERE job_id=?",
                values: [.text(state.rawValue), .real(now.timeIntervalSince1970 + delay), .text(state.rawValue), .text(job.id)])
        }
    }

    /// Cancellation is a durable revision, not deleting a queue row. It fences
    /// an in-flight completion and survives reopening. Resume is explicit.
    public func control(_ id: String, cancel: Bool, binding: LingroveNotebookWindowBinding) throws {
        try core.inTransaction {
            try check(binding)
            let job = try load(id, binding: binding)
            guard job.revision < Int64.max else { throw VocabularyError.invalidContent }
            try core.execute(sql: """
                UPDATE notebook_media_jobs SET state=?,revision=revision+1,attempt_id=NULL,process_id=NULL,
                  lease_until=NULL,next_attempt_at=NULL,error_code=NULL WHERE job_id=?
                """, values: [.text(cancel ? "cancelled" : "queued"), .text(id)])
        }
    }

    public func jobs(binding: LingroveNotebookWindowBinding) throws -> [LingroveNotebookMediaJob] {
        try core.inReadTransaction { try jobsInTransaction(binding: binding) }
    }
    public func jobsInTransaction(binding: LingroveNotebookWindowBinding) throws -> [LingroveNotebookMediaJob] {
        try check(binding)
        return try core.query(sql: "SELECT \(Self.columns) FROM notebook_media_jobs WHERE workspace_id=? AND owner_user_id=? AND notebook_id=? ORDER BY digest,direction",
            values: scope(binding), map: map)
    }

    public func retryKnown(_ binding: LingroveNotebookWindowBinding, resumeCancelled: Bool) throws {
        try core.inTransaction {
            try check(binding)
            try core.execute(sql: """
                UPDATE notebook_media_jobs SET state='queued',revision=revision+1,attempt_id=NULL,process_id=NULL,
                  lease_until=NULL,next_attempt_at=NULL,error_code=NULL
                WHERE workspace_id=? AND owner_user_id=? AND state IN ('failed','missing','queued'\(resumeCancelled ? ",'cancelled'" : ""))
                  AND revision<9223372036854775807
                """, values: [.text(workspace(binding)), .text(binding.scope.ownerUserID)])
        }
    }

    public func replacePins(_ references: [VocabularyImageReference], workspaceID: String, consumer: String) throws {
        try core.execute(sql: "DELETE FROM notebook_media_pins WHERE workspace_id=? AND consumer_id=?", values: [.text(workspaceID), .text(consumer)])
        for reference in Set(references) {
            // A failed remote release may outlive a local edit. Re-pinning is
            // atomic with removing that debt, so it can never release live data.
            try core.execute(sql: "DELETE FROM notebook_media_releases WHERE workspace_id=? AND digest=?",
                values: [.text(workspaceID), .text(reference.digest)])
            try core.execute(sql: "INSERT INTO notebook_media_pins(workspace_id,consumer_id,digest) VALUES(?,?,?)",
                values: [.text(workspaceID), .text(consumer), .text(reference.digest)])
        }
    }
    public func release(consumer: String, binding: LingroveNotebookWindowBinding) throws {
        try core.inTransaction {
            try check(binding)
            try replacePins([], workspaceID: workspace(binding), consumer: consumer)
            // Expired/discarded window caches no longer own resource pins.
            try core.execute(sql: """
                DELETE FROM notebook_media_pins WHERE workspace_id=? AND consumer_id LIKE 'window:%'
                  AND substr(consumer_id,8) NOT IN (SELECT lower(window_id) FROM notebook_download_windows WHERE workspace_id=?)
                """, values: [.text(workspace(binding)), .text(workspace(binding))])
        }
    }

    /// Reclaims operational rows only after every known consumer releases its
    /// pin. Historical journal payloads and retained remote shadow/window bytes
    /// conservatively protect references not visible in the current document.
    /// Physical files/media_assets remain owned by the shared blob lifecycle.
    public func prune(binding: LingroveNotebookWindowBinding) throws -> [VocabularyImageReference] {
        try core.inTransaction {
            try check(binding)
            let document = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: workspace(binding)).document
            try replacePins(VocabularyDocumentValidation.imageReferences(document), workspaceID: workspace(binding), consumer: "document")
            // Account adoption keeps an original private recovery copy even
            // after the active document changes. Failure to read it must abort
            // pruning rather than treating protected references as an empty set.
            try replacePins(Array(LingroveNotebookAccountStore(core: core).retainedImageReferences(workspaceID: workspace(binding))),
                workspaceID: workspace(binding), consumer: "account-recovery")
            let candidates = try core.query(sql: "SELECT \(Self.columns) FROM notebook_media_jobs WHERE workspace_id=? AND owner_user_id=? AND notebook_id=?",
                values: scope(binding), map: map)
            for job in candidates {
                let pattern = "%" + job.reference.digest + "%"
                let held = try core.scalarInt(sql: """
                    SELECT EXISTS(SELECT 1 FROM notebook_media_pins WHERE workspace_id=? AND digest=?)
                      OR EXISTS(SELECT 1 FROM notebook_pending_rows r JOIN notebook_pending_transactions t USING(operation_id) WHERE t.workspace_id=? AND r.payload_json LIKE ?)
                      OR EXISTS(SELECT 1 FROM notebook_remote_records WHERE workspace_id=? AND record_json LIKE ?)
                      OR EXISTS(SELECT 1 FROM notebook_media_jobs WHERE workspace_id=? AND digest=?
                        AND state='transferring' AND process_id=? AND lease_until>?)
                      OR EXISTS(SELECT 1 FROM notebook_download_windows WHERE workspace_id=?)
                    """, values: [.text(workspace(binding)), .text(job.reference.digest), .text(workspace(binding)), .text(pattern),
                        .text(workspace(binding)), .text(pattern), .text(workspace(binding)), .text(job.reference.digest),
                        .text(Self.processID), .real(Date().timeIntervalSince1970), .text(workspace(binding))])
                guard held == 0 else { continue }
                try core.execute(sql: """
                    INSERT INTO notebook_media_releases(workspace_id,owner_user_id,notebook_id,digest,width,height,byte_count)
                    VALUES(?,?,?,?,?,?,?) ON CONFLICT DO NOTHING
                    """, values: scope(binding) + [.text(job.reference.digest), .integer(Int64(job.reference.width)),
                        .integer(Int64(job.reference.height)), .integer(Int64(job.reference.byteCount))])
                try core.execute(sql: "DELETE FROM notebook_media_jobs WHERE job_id=?", values: [.text(job.id)])
                // The authorization mapping, registry and physical cache are
                // retained together. An open offline Card/notebook draft may
                // still read its original snapshot after the current document
                // changes; retiring this transport consumer cannot revoke it.
            }
            return try core.query(sql: """
                SELECT digest,width,height,byte_count FROM notebook_media_releases r
                WHERE workspace_id=? AND owner_user_id=? AND notebook_id=?
                  AND NOT EXISTS(SELECT 1 FROM notebook_media_pins p WHERE p.workspace_id=r.workspace_id AND p.digest=r.digest)
                """, values: scope(binding)) { s in
                VocabularyImageReference(digest: DatabaseCore.columnText(statement: s, index: 0), width: Int(sqlite3_column_int64(s, 1)),
                    height: Int(sqlite3_column_int64(s, 2)), byteCount: Int(sqlite3_column_int64(s, 3)))
            }
        }
    }

    public func acknowledgeRelease(_ reference: VocabularyImageReference, binding: LingroveNotebookWindowBinding) throws {
        try core.inTransaction {
            try check(binding)
            try core.execute(sql: "DELETE FROM notebook_media_releases WHERE workspace_id=? AND owner_user_id=? AND notebook_id=? AND digest=?",
                values: scope(binding) + [.text(reference.digest)])
        }
    }

    private func load(_ id: String, binding: LingroveNotebookWindowBinding) throws -> LingroveNotebookMediaJob {
        guard let job = try core.query(sql: "SELECT \(Self.columns) FROM notebook_media_jobs WHERE workspace_id=? AND owner_user_id=? AND notebook_id=? AND job_id=?",
            values: scope(binding) + [.text(id)], map: map).first else { throw LingroveNotebookMediaError.staleAttempt }
        return job
    }
    private func map(_ statement: OpaquePointer) throws -> LingroveNotebookMediaJob {
        guard let direction = LingroveNotebookMediaDirection(rawValue: DatabaseCore.columnText(statement: statement, index: 5)),
              let state = LingroveNotebookMediaState(rawValue: DatabaseCore.columnText(statement: statement, index: 6)),
              [2, 3, 4, 8, 9].allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }) else { throw VocabularyError.invalidContent }
        let reference = VocabularyImageReference(digest: DatabaseCore.columnText(statement: statement, index: 1),
            width: Int(sqlite3_column_int64(statement, 2)), height: Int(sqlite3_column_int64(statement, 3)), byteCount: Int(sqlite3_column_int64(statement, 4)))
        guard VocabularyContentPolicy.valid(reference) else { throw VocabularyError.invalidContent }
        let remote = DatabaseCore.columnOptionalText(statement: statement, index: 7)
        guard remote == nil || UUID(uuidString: remote!) != nil else { throw VocabularyError.invalidContent }
        return .init(id: DatabaseCore.columnText(statement: statement, index: 0), reference: reference, direction: direction, state: state,
            remoteAssetID: remote.flatMap(UUID.init(uuidString:)), attempts: Int(sqlite3_column_int64(statement, 8)),
            revision: sqlite3_column_int64(statement, 9), attemptID: DatabaseCore.columnOptionalText(statement: statement, index: 10))
    }
    private func check(_ binding: LingroveNotebookWindowBinding) throws { try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding) }
    private func scope(_ binding: LingroveNotebookWindowBinding) -> [SQLiteValue] {
        [.text(workspace(binding)), .text(binding.scope.ownerUserID), .text(binding.scope.notebookID.uuidString.lowercased())]
    }
    private func workspace(_ binding: LingroveNotebookWindowBinding) -> String { binding.scope.workspaceID.uuidString.lowercased() }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
