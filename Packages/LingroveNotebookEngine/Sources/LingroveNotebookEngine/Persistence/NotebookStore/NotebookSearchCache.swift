import CryptoKit
import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec
import SQLite3

/// Rebuildable search data belongs to the primary database, separately from canonical rows.
/// Workspace deletion cascades through it; backups/sync never export these tables. A local
/// writer journals only its admitted entry delta in the same transaction as the corpus change.
/// Neither a cached payload nor this journal can authorize a corpus/review write.
enum NotebookSearchCache {
    static let format = 3
    static let maximumBytes = 128 * 1_024 * 1_024
    static let maximumJournalBytes = 8 * 1_024 * 1_024
    static let maximumJournalFrames = 64
    static let compactAfterFrames = 8
    static let compactAfterBytes = 512 * 1_024
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
        struct Owner: Codable {
            let entryID: UUID
            let previousSenseIDs: Set<UUID>
            let entry: VocabularyEntry?
        }
        struct TagRemoval: Codable {
            let tag: String
            let counts: [UUID: Int]
        }
        let base: NotebookBrowseFence
        let fence: NotebookBrowseFence
        let owners: [Owner]
        let tagRemoval: TagRemoval?
        init(base: NotebookBrowseFence, fence: NotebookBrowseFence, owners: [Owner], tagRemoval: TagRemoval? = nil) {
            self.base = base; self.fence = fence; self.owners = owners; self.tagRemoval = tagRemoval
        }
        var hasValidShape: Bool {
            guard owners.count <= 100, Set(owners.map(\.entryID)).count == owners.count else { return false }
            guard let tagRemoval else { return true }
            return owners.isEmpty && !tagRemoval.tag.isEmpty && tagRemoval.tag.utf8.count <= 200 &&
                !tagRemoval.counts.isEmpty && tagRemoval.counts.values.allSatisfy { (1...100).contains($0) }
        }
    }

    /// The transaction records bounded, admitted entry deltas, never a full search payload.
    /// Any missing frame, semantic change, shared evidence edit or rollback breaks the clock
    /// chain and requests canonical preparation. Cached data cannot certify these writers.
    static func record(in core: DatabaseCore, base: NotebookBrowseFence,
                       commit: LingroveNotebookEntryCommit) throws {
        guard !commit.changesSemantics, commit.version != commit.base else { return }
        try append(in: core, edit: .init(base: base, fence: .init(version: commit.version, corpus: commit.corpus),
            owners: [.init(entryID: commit.entryID, previousSenseIDs: commit.previousSenseIDs, entry: commit.entry)]))
    }

    static func record(in core: DatabaseCore, base: NotebookBrowseFence,
                       plan: LingroveNotebookSavePlan, previous: LingroveNotebookSnapshot, entries previousEntries: [VocabularyEntry], saved: LingroveNotebookSnapshot) throws {
        if let removal = plan.tagRemoval {
            try append(in: core, edit: .init(base: base, fence: .init(version: .init(saved), corpus: core.notebookCacheToken()),
                owners: [], tagRemoval: .init(tag: removal.tag, counts: removal.removedBySense)))
            return
        }
        guard plan.entryIDs.count <= 100,
              try core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_cache WHERE workspace_id=? AND format_version=?",
                values: [.text(base.version.workspaceId), .integer(Int64(format))]) == 1 else { return }
        let semantic: Set<VocabularyPersistenceEntity> = [.meaningNodes, .meaningLabels, .meaningRoles,
            .usagePatterns, .patternSlots, .meaningMappings, .mappingRoles, .mappingEvidence, .meaningRelations, .retrievalCues, .cueTargets]
        let rows = plan.rows.changed + plan.rows.removed + plan.rows.repositioned
        guard !rows.contains(where: { semantic.contains($0.key.entity) }) else { return }
        let evidence = rows.filter { $0.key.entity == .sources || $0.key.entity == .occurrences }
        if !evidence.isEmpty {
            let sources = Set(previous.document.sources.map(\.id)), occurrences = Set(previous.document.occurrences.map(\.id))
            guard !evidence.contains(where: {
                guard let id = UUID(uuidString: $0.key.id) else { return true }
                return $0.key.entity == .sources ? sources.contains(id) : occurrences.contains(id)
            }) else { return }
        }
        let old = Dictionary(uniqueKeysWithValues: previousEntries.filter { plan.entryIDs.contains($0.id) }.map { ($0.id,$0) })
        let next = Dictionary(uniqueKeysWithValues: plan.state.entries.filter { plan.entryIDs.contains($0.id) }.map { ($0.id,$0) })
        try append(in: core, edit: .init(base: base, fence: .init(version: .init(saved), corpus: core.notebookCacheToken()),
            owners: plan.entryIDs.map { .init(entryID: $0, previousSenseIDs: Set(old[$0]?.senses.flatMap { [$0.id] + $0.mergedFrom } ?? []), entry: next[$0]) }))
    }

    private static func append(in core: DatabaseCore, edit: EntryEdit) throws {
        let workspace = edit.base.version.workspaceId
        guard edit.hasValidShape, try core.scalarInt(sql: "SELECT count(*) FROM notebook_literal_search_cache WHERE workspace_id=? AND format_version=?",
            values: [.text(workspace), .integer(Int64(format))]) == 1 else { return }
        let bytes = try encode(edit)
        guard bytes.count <= maximumJournalBytes else { return }
        let usage = try core.query(sql: "SELECT count(*),coalesce(sum(length(payload)),0) FROM notebook_literal_search_updates WHERE workspace_id=?",
            values: [.text(workspace)]) { (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1))) }.first
        if let usage, usage.0 >= maximumJournalFrames || usage.1 + bytes.count > maximumJournalBytes {
            try core.execute(sql: "DELETE FROM notebook_literal_search_updates WHERE workspace_id=?", values: [.text(workspace)])
        }
        try core.execute(sql: "INSERT INTO notebook_literal_search_updates(workspace_id,payload,sha256) VALUES(?,?,?)",
            values: [.text(workspace), .blob(bytes), .text(digest(bytes))])
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

/// The engine prepares verified retrieval material and names optional cache maintenance.
/// Hosts may return the material first and checkpoint later on their connection owner. A
/// preparation cannot be authored by a host and never authorizes canonical/review writes.
public struct NotebookSearchPreparation: Sendable {
    public let material: NotebookLiteralSearchMaterial
    public let requiresCheckpoint: Bool
    fileprivate init(material: NotebookLiteralSearchMaterial, requiresCheckpoint: Bool) {
        self.material = material; self.requiresCheckpoint = requiresCheckpoint
    }
}

extension LingroveNotebookEngine {
    /// A page actor can reuse memory, then durable projection data, then canonical scalars.
    /// Every path uses the exact current corpus/owner fence. Persisting is best effort and
    /// separate from the read; cancellation and source conflicts still propagate normally.
    public func prepareNotebookSearch(reusing previous: NotebookLiteralSearchMaterial? = nil,
                                      locale: String = Locale.current.identifier) throws -> NotebookLiteralSearchMaterial {
        let preparation = try prepareNotebookSearchForBrowsing(reusing: previous, locale: locale)
        try checkpointNotebookSearch(preparation)
        return preparation.material
    }

    /// Read-only preparation returns without encoding/fsyncing an optional complete cache.
    /// The caller owns maintenance scheduling; the later write checks the exact SQL fence.
    public func prepareNotebookSearchForBrowsing(reusing previous: NotebookLiteralSearchMaterial? = nil,
                                                locale: String = Locale.current.identifier) throws -> NotebookSearchPreparation {
        let hit: (material: NotebookLiteralSearchMaterial, compact: Bool)?
        do { hit = try core.inReadTransaction { try cachedNotebookSearch(previous: previous, locale: locale) } }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return try uncheckpointedNotebookSearch(locale: locale) }
        if let hit {
            return .init(material: hit.material, requiresCheckpoint: hit.compact)
        }
        return try uncheckpointedNotebookSearch(locale: locale)
    }

    public func checkpointNotebookSearch(_ preparation: NotebookSearchPreparation) throws {
        guard preparation.requiresCheckpoint else { return }
        try persistNotebookSearch(preparation.material)
    }

    private func uncheckpointedNotebookSearch(locale: String) throws -> NotebookSearchPreparation {
        .init(material: try notebookLiteralSearchMaterial(locale: locale), requiresCheckpoint: true)
    }

    private func cachedNotebookSearch(previous: NotebookLiteralSearchMaterial?, locale: String) throws -> (material: NotebookLiteralSearchMaterial, compact: Bool)? {
        try Task.checkCancellation()
        let fence = try browseFenceInTransaction()
        if let previous, previous.fence == fence {
            var hit = previous.localized(locale); hit.preparation = .memory; return (hit, false)
        }
        guard try core.tableExists(name: "notebook_literal_search_cache") else { return nil }
        let rows = try core.query(sql: """
            SELECT fence_json FROM notebook_literal_search_cache
            WHERE workspace_id=? AND format_version=? AND length(payload) BETWEEN 1 AND ?
            """, values: [.text(fence.version.workspaceId), .integer(Int64(NotebookSearchCache.format)),
                .integer(Int64(NotebookSearchCache.maximumBytes))]) { DatabaseCore.columnText(statement: $0, index: 0) }
        guard let row = rows.first,
              let base = try? JSONDecoder().decode(NotebookBrowseFence.self, from: Data(row.utf8)),
              base.version.hasSameOwner(as: fence.version), base.corpus.schemaVersion == fence.corpus.schemaVersion,
              base.corpus.epoch == fence.corpus.epoch, base.version.revision <= fence.version.revision,
              base.corpus.value >= 0, base.corpus.value <= fence.corpus.value else { return nil }
        let usage = try core.query(sql: "SELECT count(*),coalesce(sum(length(payload)),0) FROM notebook_literal_search_updates WHERE workspace_id=?",
            values: [.text(fence.version.workspaceId)]) { (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1))) }.first
        guard let usage, usage.0 <= NotebookSearchCache.maximumJournalFrames,
              usage.1 <= NotebookSearchCache.maximumJournalBytes else { return nil }
        let updates = try core.query(sql: """
            SELECT payload,sha256 FROM notebook_literal_search_updates WHERE workspace_id=? ORDER BY sequence
            """, values: [.text(fence.version.workspaceId)]) { row in
                (NotebookSearchCache.blob(row, 0), DatabaseCore.columnText(statement: row, index: 1))
            }
        var cursor = base, edits: [NotebookSearchCache.EntryEdit] = []
        var suffix = previous?.fence == base ? 0 : nil
        for update in updates {
            try Task.checkCancellation()
            guard let edit = NotebookSearchCache.decode(NotebookSearchCache.EntryEdit.self, bytes: update.0, sha256: update.1),
                  edit.hasValidShape,
                  edit.base == cursor, edit.fence.version.hasSameOwner(as: fence.version),
                  edit.fence.corpus.epoch == cursor.corpus.epoch,
                  edit.fence.corpus.schemaVersion == cursor.corpus.schemaVersion,
                  cursor.version.revision < UInt64(Int64.max),
                  edit.fence.version.revision == cursor.version.revision + 1,
                  edit.fence.corpus.value > cursor.corpus.value,
                  edit.fence.corpus.value <= fence.corpus.value else { return nil }
            edits.append(edit); cursor = edit.fence
            if previous?.fence == cursor { suffix = edits.count }
        }
        guard cursor == fence else { return nil }
        var material: NotebookLiteralSearchMaterial
        if let previous, suffix != nil { material = previous.localized(locale) }
        else {
            let blobs = try core.query(sql: "SELECT payload,sha256 FROM notebook_literal_search_cache WHERE workspace_id=?",
                values: [.text(fence.version.workspaceId)]) { (NotebookSearchCache.blob($0, 0), DatabaseCore.columnText(statement: $0, index: 1)) }
            guard let blob = blobs.first, NotebookSearchCache.digest(blob.0) == blob.1,
                  let payload = NotebookSearchBinaryCodec.decode(blob.0),
                  let restored = payload.material(fence: base, locale: locale) else { return nil }
            material = restored; suffix = 0
        }
        let remaining = Array(edits.dropFirst(suffix ?? 0))
        if !remaining.isEmpty {
            guard let updated = material.applying(remaining) else { try Task.checkCancellation(); return nil }
            material = updated
        }
        try Task.checkCancellation()
        if base == fence { material.preparation = .persisted; return (material, false) }
        material.preparation = .incremental
        // Small edits retain the bounded journal. Amortize full encoding/fsync over multiple
        // reads; a later reader without memory still verifies/replays the complete chain once.
        return (material, edits.count >= NotebookSearchCache.compactAfterFrames || usage.1 >= NotebookSearchCache.compactAfterBytes)
    }

    private func persistNotebookSearch(_ material: NotebookLiteralSearchMaterial) throws {
        try Task.checkCancellation()
        guard try core.withConnectionAccess({ sqlite3_db_readonly(core.connection, "main") == 0 }),
              try core.tableExists(name: "notebook_literal_search_cache") else { return }
        // Reject a superseded preparation before allocating its encoded payload, then repeat
        // the check in the transaction so edits/account changes during encoding cannot win.
        guard try notebookBrowseFence() == material.fence else { throw VocabularyError.editConflict }
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
