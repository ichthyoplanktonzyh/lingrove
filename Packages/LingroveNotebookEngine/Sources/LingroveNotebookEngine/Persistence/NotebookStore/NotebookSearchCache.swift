import CryptoKit
import Foundation
import LingroveNotebook
import SQLite3

/// Rebuildable search data belongs to the primary database, separately from canonical rows.
/// Workspace deletion cascades through it; backups/sync never export these tables. A local
/// writer journals only its admitted entry delta in the same transaction as the corpus change.
/// Neither a cached payload nor this journal can authorize a corpus/review write.
enum NotebookSearchCache {
    static let format = 2
    static let maximumBytes = 128 * 1_024 * 1_024
    static func ensureInstalled(in core: DatabaseCore) throws {
        guard try !core.tableExists(name: "notebook_literal_search_cache") ||
                !core.tableExists(name: "notebook_literal_search_updates") else { return }
        try core.inTransaction {
            try core.executeScript(sql: """
                CREATE TABLE IF NOT EXISTS notebook_literal_search_cache (
                    workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
                    format_version INTEGER NOT NULL, fence_json TEXT NOT NULL,
                    payload BLOB NOT NULL, sha256 TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS notebook_literal_search_updates (
                    sequence INTEGER PRIMARY KEY,
                    workspace_id TEXT NOT NULL REFERENCES notebook_literal_search_cache(workspace_id) ON DELETE CASCADE,
                    payload BLOB NOT NULL, sha256 TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS notebook_literal_search_update_owners
                    ON notebook_literal_search_updates(workspace_id,sequence);
                """, errorContext: "Create rebuildable notebook search projection")
        }
    }

    struct EntryEdit: Codable {
        let base: NotebookBrowseFence
        let fence: NotebookBrowseFence
        let entryID: UUID
        let previousSenseIDs: Set<UUID>
        let entry: VocabularyEntry?
    }

    /// Only the certified closed-entry writer calls this, after all canonical statements.
    /// A missing delta, raw SQL, semantic edit or rollback breaks the exact clock chain and
    /// forces canonical preparation. Saving one entry never encodes the complete search cache.
    static func record(in core: DatabaseCore, base: NotebookBrowseFence,
                       commit: LingroveNotebookEntryCommit) throws {
        guard !commit.changesSemantics, commit.version != commit.base,
              try core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_cache WHERE workspace_id=?",
                values: [.text(base.version.workspaceId)]) == 1 else { return }
        let count = try core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_updates WHERE workspace_id=?",
            values: [.text(base.version.workspaceId)])
        if count >= 64 {
            try core.execute(sql: "DELETE FROM notebook_literal_search_updates WHERE workspace_id=?", values: [.text(base.version.workspaceId)])
        }
        let edit = EntryEdit(base: base, fence: .init(version: commit.version, corpus: commit.corpus),
            entryID: commit.entryID, previousSenseIDs: commit.previousSenseIDs, entry: commit.entry)
        let bytes = try encode(edit)
        try core.execute(sql: "INSERT INTO notebook_literal_search_updates(workspace_id,payload,sha256) VALUES(?,?,?)",
            values: [.text(base.version.workspaceId), .blob(bytes), .text(digest(bytes))])
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, bytes: Data, sha256: String) -> T? {
        guard bytes.count <= maximumBytes, digest(bytes) == sha256 else { return nil }
        return try? PropertyListDecoder().decode(type, from: bytes)
    }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func blob(_ row: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(row, index))
        guard sqlite3_column_type(row, index) == SQLITE_BLOB, count > 0, count <= maximumBytes,
              let pointer = sqlite3_column_blob(row, index) else { return Data() }
        // The statement owns the borrowed pointer; copy before its next step/finalization.
        return Data(bytes: pointer, count: count)
    }
}

extension LingroveNotebookEngine {
    /// A page actor can reuse memory, then durable projection data, then canonical scalars.
    /// Every path uses the exact current corpus/owner fence. Persisting is best effort and
    /// separate from the read; cancellation and source conflicts still propagate normally.
    public func prepareNotebookSearch(reusing previous: NotebookLiteralSearchMaterial? = nil,
                                      locale: String = Locale.current.identifier) throws -> NotebookLiteralSearchMaterial {
        let hit: NotebookLiteralSearchMaterial?
        do { hit = try core.inReadTransaction { try cachedNotebookSearch(previous: previous, locale: locale) } }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return try rebuildNotebookSearch(locale: locale) }
        if let hit {
            if hit.preparation == .incremental { try persistNotebookSearch(hit) }
            return hit
        }
        return try rebuildNotebookSearch(locale: locale)
    }

    private func rebuildNotebookSearch(locale: String) throws -> NotebookLiteralSearchMaterial {
        let material = try notebookLiteralSearchMaterial(locale: locale)
        try persistNotebookSearch(material)
        return material
    }

    private func cachedNotebookSearch(previous: NotebookLiteralSearchMaterial?, locale: String) throws -> NotebookLiteralSearchMaterial? {
        try Task.checkCancellation()
        let fence = try browseFenceInTransaction()
        if let previous, previous.fence == fence {
            var hit = previous.localized(locale); hit.preparation = .memory; return hit
        }
        guard try core.tableExists(name: "notebook_literal_search_cache") else { return nil }
        let rows = try core.query(sql: """
            SELECT fence_json,payload,sha256 FROM notebook_literal_search_cache
            WHERE workspace_id=? AND format_version=? AND length(payload)<=?
            """, values: [.text(fence.version.workspaceId), .integer(Int64(NotebookSearchCache.format)),
                .integer(Int64(NotebookSearchCache.maximumBytes))]) { row in
                (DatabaseCore.columnText(statement: row, index: 0), NotebookSearchCache.blob(row, 1),
                 DatabaseCore.columnText(statement: row, index: 2))
            }
        guard let row = rows.first,
              let base = try? JSONDecoder().decode(NotebookBrowseFence.self, from: Data(row.0.utf8)),
              base.version.hasSameOwner(as: fence.version), base.corpus.schemaVersion == fence.corpus.schemaVersion,
              base.corpus.epoch == fence.corpus.epoch else { return nil }
        var material: NotebookLiteralSearchMaterial
        if let previous, previous.fence == base { material = previous.localized(locale) }
        else {
            guard NotebookSearchCache.digest(row.1) == row.2,
                  let payload = NotebookSearchBinaryCodec.decode(row.1),
                  let restored = payload.material(fence: base, locale: locale) else { return nil }
            material = restored
        }
        if base == fence { material.preparation = .persisted; return material }
        let updates = try core.query(sql: """
            SELECT payload,sha256 FROM notebook_literal_search_updates WHERE workspace_id=? ORDER BY sequence
            """, values: [.text(fence.version.workspaceId)]) { row in
                (NotebookSearchCache.blob(row, 0), DatabaseCore.columnText(statement: row, index: 1))
            }
        var cursor = base
        for update in updates {
            try Task.checkCancellation()
            guard let edit = NotebookSearchCache.decode(NotebookSearchCache.EntryEdit.self, bytes: update.0, sha256: update.1),
                  edit.base == cursor, edit.fence.version.hasSameOwner(as: fence.version),
                  edit.fence.corpus.epoch == cursor.corpus.epoch,
                  edit.fence.corpus.schemaVersion == cursor.corpus.schemaVersion,
                  edit.fence.version.revision == cursor.version.revision + 1,
                  edit.fence.corpus.value > cursor.corpus.value,
                  let next = material.applying(edit) else { return nil }
            material = next; cursor = edit.fence
        }
        guard cursor == fence else { return nil }
        material.preparation = .incremental
        // The caller compacts after ending this read transaction, never in an editor's Save.
        return material
    }

    private func persistNotebookSearch(_ material: NotebookLiteralSearchMaterial) throws {
        try Task.checkCancellation()
        guard try core.withConnectionAccess({ sqlite3_db_readonly(core.connection, "main") == 0 }),
              try core.tableExists(name: "notebook_literal_search_cache") else { return }
        guard let bytes = NotebookSearchBinaryCodec.encode(NotebookSearchProjection(material)) else { return }
        do {
            try core.inTransaction {
                try Task.checkCancellation()
                guard try browseFenceInTransaction() == material.fence else { throw VocabularyError.editConflict }
                try core.execute(sql: """
                    INSERT INTO notebook_literal_search_cache(workspace_id,format_version,fence_json,payload,sha256)
                    VALUES(?,?,?,?,?) ON CONFLICT(workspace_id) DO UPDATE SET format_version=excluded.format_version,
                    fence_json=excluded.fence_json,payload=excluded.payload,sha256=excluded.sha256
                    """, values: [.text(material.fence.version.workspaceId), .integer(Int64(NotebookSearchCache.format)),
                        .text(String(decoding: try JSONEncoder().encode(material.fence), as: UTF8.self)),
                        .blob(bytes), .text(NotebookSearchCache.digest(bytes))])
                try core.execute(sql: "DELETE FROM notebook_literal_search_updates WHERE workspace_id=?", values: [.text(material.fence.version.workspaceId)])
            }
        } catch is CancellationError { throw CancellationError() }
        catch VocabularyError.editConflict { throw VocabularyError.editConflict }
        catch { /* An optional projection must not make valid canonical search unavailable. */ }
    }
}
