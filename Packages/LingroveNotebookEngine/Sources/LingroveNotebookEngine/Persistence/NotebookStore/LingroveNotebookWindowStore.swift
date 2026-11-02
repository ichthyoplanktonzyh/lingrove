import Foundation
import LingroveNotebookSync
import SQLite3

/// Captured before a request starts. It binds a trusted remote scope to one
/// durable local account/workspace generation; a response cannot choose it.
public nonisolated struct LingroveNotebookWindowBinding: Equatable, Sendable {
    public let scope: VocabularyWireWindowScope
    public let generation: String

    public init(scope: VocabularyWireWindowScope, generation: String) {
        self.scope = scope
        self.generation = generation
    }
}
public nonisolated struct LingroveNotebookWindowProgress: Sendable {
    public let manifest: VocabularyWireWindowManifest
    public let receivedOrdinals: [Int]

    public init(manifest: VocabularyWireWindowManifest, receivedOrdinals: [Int]) {
        self.manifest = manifest
        self.receivedOrdinals = receivedOrdinals
    }
}
public nonisolated enum LingroveNotebookWindowStoreError: Error, Equatable {
    case bindingChanged, missingWindow, identityConflict, pageConflict, windowLimit, corruptStage
}

/// LocalDatabase owns this stateless adapter and its single Core connection.
/// Only incoming cache tables change here. Completion returns a transport proof;
/// it does not adopt a book, replace user edits, acknowledge pending operations,
/// enroll review or advance a sync cursor. The eventual apply writer owns that
/// separate transaction after resolving local edits and private tool state.
public struct LingroveNotebookWindowStore {
    public let core: DatabaseCore
    private static let identity = "binding_generation=? AND workspace_id=? AND owner_user_id=? AND notebook_id=? AND replica_id=? AND window_id=?"

    public func capture(scope: VocabularyWireWindowScope) throws -> LingroveNotebookWindowBinding {
        try core.inReadTransaction {
            let binding = LingroveNotebookWindowBinding(scope: scope, generation: try LingroveNotebookLocalScopeStore(core: core).generationInTransaction())
            try check(binding); return binding
        }
    }
    public func begin(_ manifest: VocabularyWireWindowManifest, binding: LingroveNotebookWindowBinding, now: Date) throws -> LingroveNotebookWindowProgress {
        try core.inTransaction {
            try check(binding); try manifest.validate(expecting: binding.scope, now: now)
            try purgeExpiredRows(now: now)
            if let existing = try readManifest(binding: binding, windowID: manifest.windowID) {
                guard existing.manifestSHA256 == manifest.manifestSHA256 else { throw LingroveNotebookWindowStoreError.identityConflict }
                return try readProgress(binding: binding, windowID: manifest.windowID, now: now)
            }
            let id = values(binding, windowID: manifest.windowID)
            let active = try core.scalarInt(sql: """
                SELECT count(*) FROM notebook_download_windows
                WHERE binding_generation=? AND workspace_id=? AND owner_user_id=? AND notebook_id=? AND replica_id=?
                """, values: Array(id.dropLast()))
            guard active < 2 else { throw LingroveNotebookWindowStoreError.windowLimit }
            try core.execute(sql: """
                INSERT INTO notebook_download_windows(binding_generation,workspace_id,owner_user_id,notebook_id,replica_id,window_id,manifest_sha256,manifest_json,expires_at_ms)
                VALUES(?,?,?,?,?,?,?,?,?)
                """, values: id + [.text(manifest.manifestSHA256), .text(try core.encodeJsonString(value: manifest)), .integer(Int64(manifest.expiresAtMilliseconds))])
            return .init(manifest: manifest, receivedOrdinals: [])
        }
    }
    public func receive(_ page: VocabularyWireWindowPage, binding: LingroveNotebookWindowBinding, manifestSHA256: String, now: Date) throws {
        try core.inTransaction {
            try check(binding)
            let manifest = try requireManifest(binding: binding, windowID: page.windowID, sha: manifestSHA256, now: now)
            _ = try page.verifiedBytes(for: manifest, expecting: binding.scope, now: now)
            let id = values(binding, windowID: page.windowID) + [.integer(Int64(page.ordinal))]
            let prior = try core.query(sql: "SELECT body_base64,sha256,byte_count FROM notebook_download_pages WHERE \(Self.identity) AND ordinal=?", values: id) { statement in
                guard sqlite3_column_type(statement, 2) == SQLITE_INTEGER else { throw LingroveNotebookWindowStoreError.corruptStage }
                return (try Self.text(statement, 0), try Self.text(statement, 1), sqlite3_column_int64(statement, 2))
            }
            if let prior = prior.first {
                guard prior.0 == page.data, prior.1 == page.sha256, prior.2 == Int64(page.byteCount) else { throw LingroveNotebookWindowStoreError.pageConflict }
                return
            }
            try core.execute(sql: """
                INSERT INTO notebook_download_pages(binding_generation,workspace_id,owner_user_id,notebook_id,replica_id,window_id,ordinal,body_base64,sha256,byte_count)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """, values: id + [.text(page.data), .text(page.sha256), .integer(Int64(page.byteCount))])
        }
    }
    public func progress(binding: LingroveNotebookWindowBinding, windowID: UUID, now: Date) throws -> LingroveNotebookWindowProgress {
        try core.inTransaction {
            try readProgress(binding: binding, windowID: windowID, now: now)
        }
    }
    /// Both public progress reads and begin retries already own a transaction.
    /// DatabaseCore does not nest transactions, so the shared SQL reader must
    /// borrow that transaction rather than starting another BEGIN IMMEDIATE.
    private func readProgress(binding: LingroveNotebookWindowBinding, windowID: UUID, now: Date) throws -> LingroveNotebookWindowProgress {
        try check(binding)
        guard let manifest = try readManifest(binding: binding, windowID: windowID) else { throw LingroveNotebookWindowStoreError.missingWindow }
        try manifest.validate(expecting: binding.scope, now: now)
        let ordinals = try core.query(sql: "SELECT ordinal FROM notebook_download_pages WHERE \(Self.identity) ORDER BY ordinal", values: values(binding, windowID: windowID)) { statement in
            let ordinal = sqlite3_column_int64(statement, 0)
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER, ordinal >= 0, ordinal < Int64(manifest.pageCount) else { throw LingroveNotebookWindowStoreError.corruptStage }
            return Int(ordinal)
        }
        return .init(manifest: manifest, receivedOrdinals: ordinals)
    }
    public func complete(binding: LingroveNotebookWindowBinding, windowID: UUID, manifestSHA256: String, now: Date) throws -> VocabularyWireVerifiedWindow {
        let clock = ContinuousClock()
        let started = clock.now
        func currentLeaseTime() -> Date {
            let elapsed = started.duration(to: clock.now).components
            return now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000)
        }
        var staged = try core.inTransaction {
            try check(binding)
            let manifest = try requireManifest(binding: binding, windowID: windowID, sha: manifestSHA256, now: now)
            var verifier = try VocabularyWireWindowAccumulator(manifest: manifest, expecting: binding.scope, now: now)
            var json = Data()
            // Read/verify each SQL row while the same read transaction owns the
            // stage. No completed flag, decoded-text fallback or retained array
            // of base64 strings can hide missing/corrupted pages on a restart.
            _ = try core.query(sql: "SELECT ordinal,body_base64,sha256,byte_count FROM notebook_download_pages WHERE \(Self.identity) ORDER BY ordinal", values: values(binding, windowID: windowID)) { statement -> Bool in
                let ordinal = sqlite3_column_int64(statement, 0), bytes = sqlite3_column_int64(statement, 3)
                guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER, sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
                      ordinal >= 0, ordinal <= Int64(Int32.max), bytes > 0, bytes <= Int64(VocabularyWireWindowManifest.pageBytes) else { throw LingroveNotebookWindowStoreError.corruptStage }
                let page = try VocabularyWireWindowPage(windowID: windowID, ordinal: Int(ordinal), data: Self.text(statement, 1), sha256: Self.text(statement, 2), byteCount: Int(bytes))
                json.append(try verifier.accept(page, now: currentLeaseTime())); return true
            }
            return (verifier: verifier, json: json)
        }
        // Whole-record decoding does not reserve the SQLite writer lock. The
        // bytes are already copied; recheck the binding/lease afterwards so an
        // account switch or discard during decoding cannot return a stale proof.
        let verified = try staged.verifier.finish(recordsJSON: staged.json, now: currentLeaseTime())
        try core.inTransaction {
            try check(binding)
            _ = try requireManifest(binding: binding, windowID: windowID, sha: manifestSHA256, now: currentLeaseTime())
        }
        return verified
    }
    public func discard(binding: LingroveNotebookWindowBinding, windowID: UUID) throws {
        try core.inTransaction {
            try check(binding)
            try core.execute(sql: "DELETE FROM notebook_download_windows WHERE \(Self.identity)", values: values(binding, windowID: windowID))
        }
    }
    public func purgeExpired(now: Date) throws { try core.inTransaction { try purgeExpiredRows(now: now) } }
    /// Compound apply readers/writers already hold the Core transaction. Borrow
    /// its binding fence without opening a nested SQLite transaction.
    public func checkBindingInTransaction(_ binding: LingroveNotebookWindowBinding) throws { try check(binding) }
    private func purgeExpiredRows(now: Date) throws {
        let value = now.timeIntervalSince1970 * 1000
        guard value.isFinite, abs(value) <= 9_007_199_254_740_991 else { throw VocabularyWireWindowError.invalidManifest }
        try core.execute(sql: "DELETE FROM notebook_download_windows WHERE expires_at_ms<=?", values: [.integer(Int64(value.rounded(.down)))])
    }
    private func check(_ binding: LingroveNotebookWindowBinding) throws {
        guard try LingroveNotebookLocalScopeStore(core: core).generationInTransaction() == binding.generation else { throw LingroveNotebookWindowStoreError.bindingChanged }
        let scope = binding.scope
        let count = try core.scalarInt(sql: """
            SELECT count(*) FROM app_local_settings WHERE settings_id=1 AND cloud_state IN ('guest','linked')
              AND linked_user_id=? COLLATE BINARY AND lower(linked_workspace_id)=? AND lower(active_workspace_id)=?
            """, values: [.text(scope.ownerUserID), .text(scope.workspaceID.uuidString.lowercased()), .text(scope.workspaceID.uuidString.lowercased())])
        guard count == 1 else { throw LingroveNotebookWindowStoreError.bindingChanged }
    }
    private func readManifest(binding: LingroveNotebookWindowBinding, windowID: UUID) throws -> VocabularyWireWindowManifest? {
        let rows = try core.query(sql: "SELECT manifest_json,manifest_sha256,expires_at_ms FROM notebook_download_windows WHERE \(Self.identity)", values: values(binding, windowID: windowID)) { statement in
            let manifest = try self.core.decoder.decode(VocabularyWireWindowManifest.self, from: Data(Self.text(statement, 0).utf8))
            guard sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                  manifest.manifestSHA256 == (try Self.text(statement, 1)), Int64(manifest.expiresAtMilliseconds) == sqlite3_column_int64(statement, 2),
                  manifest.windowID == windowID, manifest.scope == binding.scope else { throw LingroveNotebookWindowStoreError.corruptStage }
            return manifest
        }
        return rows.first
    }
    private func requireManifest(binding: LingroveNotebookWindowBinding, windowID: UUID, sha: String, now: Date) throws -> VocabularyWireWindowManifest {
        guard let manifest = try readManifest(binding: binding, windowID: windowID) else { throw LingroveNotebookWindowStoreError.missingWindow }
        guard manifest.manifestSHA256 == sha else { throw LingroveNotebookWindowStoreError.identityConflict }
        try manifest.validate(expecting: binding.scope, now: now); return manifest
    }
    private func values(_ binding: LingroveNotebookWindowBinding, windowID: UUID) -> [SQLiteValue] {
        [.text(binding.generation), .text(binding.scope.workspaceID.uuidString.lowercased()), .text(binding.scope.ownerUserID),
            .text(binding.scope.notebookID.uuidString.lowercased()), .text(binding.scope.replicaID.uuidString.lowercased()), .text(windowID.uuidString.lowercased())]
    }
    /// Copy SQLite-owned UTF-8 before finalizing the statement; JSON/base64 cannot
    /// be reconstructed through a replacement-character display convenience.
    private static func text(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let pointer = sqlite3_column_text(statement, index),
              let value = String(bytes: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, index))), encoding: .utf8) else { throw LingroveNotebookWindowStoreError.corruptStage }
        return value
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
