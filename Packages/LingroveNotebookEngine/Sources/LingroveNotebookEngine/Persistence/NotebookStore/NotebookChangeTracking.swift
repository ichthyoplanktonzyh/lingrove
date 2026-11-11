import Foundation
import LingroveNotebookPersistenceCodec
import SQLite3

/// Derived database metadata, installed once per schema rather than maintained by individual
/// commands. Raw SQL and foreign-key cascades must invalidate the same caches as app saves.
/// Counters are database-wide: edits in a retained workspace conservatively invalidate that
/// domain too, because an ownership proposal can depend on two different workspaces.
enum NotebookChangeTracking {
    // Bump when dependencies/ignored columns change. Installation atomically replaces older
    // trigger definitions so an existing database adopts the same rules as a fresh one.
    private static let triggerVersion = 1
    /// Installation-only values map one physical table to its readers. They are discarded
    /// after generating triggers; no separate in-memory mutation registry needs synchronization.
    private struct Dependency {
        let table: String
        let domains: NotebookChangeDomains
        var ignoredUpdates: Set<String> = []
    }

    private static var dependencies: [Dependency] {
        var result = VocabularyPersistenceEntity.allCases.map {
            Dependency(table: LingroveNotebookSchema.table($0), domains: $0 == .senses ? [.corpus, .progress] : .corpus)
        }
        result += [Dependency(table: "notebook_state", domains: .corpus)]
        let reviewAndProgress: NotebookChangeDomains = [.review, .progress]
        result += ["cards", "review_events", "notebook_card_links", "notebook_review_enrollments",
                   "notebook_review_exercises", "notebook_review_material_state"].map {
            Dependency(table: $0, domains: reviewAndProgress)
        }
        // An upload ACK only clears `pending`; it does not undo a different event or change
        // the stored schedule. Advancing the UI clock for it would restart an active question.
        result += [.init(table: "notebook_review_undo", domains: reviewAndProgress, ignoredUpdates: ["pending"])]
        result += ["notebook_review_schedule_heads",
                   "notebook_review_last_rating", "notebook_notes", "notebook_note_types",
                   "notebook_note_cards", "media_assets", "notebook_media_assets"].map {
            Dependency(table: $0, domains: .review)
        }
        result += [.init(table: "notebook_review_media", domains: .review, ignoredUpdates: ["acknowledged"])]
        result += [.init(table: "media_blob_cache", domains: .review, ignoredUpdates: ["last_accessed_at"])]
        result += ["notebook_ownership_proposals", "notebook_first_connections", "notebook_account_scopes",
                   "notebook_active_endpoint", "app_local_settings", "notebook_window_binding"].map {
            Dependency(table: $0, domains: .ownership)
        }
        result += ["notebook_pending_transactions", "outbox", "notebook_held_card_operations",
                   "notebook_card_link_operations", "notebook_review_operations", "notebook_review_history_adoptions",
                   "notebook_note_sync_state", "notebook_review_material_confirmations",
                   "notebook_media_jobs", "notebook_media_pins", "notebook_media_releases"].map {
            Dependency(table: $0, domains: .synchronization)
        }
        result += [.init(table: "workspaces", domains: [.review, .synchronization])]
        return result
    }

    /// Additive metadata upgrade; document format and user_version remain unchanged. Checking
    /// every required trigger also repairs an interrupted installation before writes escape.
    static func ensureInstalled(in core: DatabaseCore) throws {
        let dependencies = dependencies
        if try isInstalled(in: core) { return }
        try core.inTransaction {
            let obsolete = try core.query(sql: "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'notebook_clock_%'",
                values: []) { DatabaseCore.columnText(statement: $0, index: 0) }
            for name in obsolete {
                let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
                try core.executeScript(sql: "DROP TRIGGER \"\(quoted)\";", errorContext: "Replace notebook dependency trigger")
            }
            try core.executeScript(sql: """
                CREATE TABLE IF NOT EXISTS notebook_change_clock (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1), epoch TEXT NOT NULL,
                    corpus INTEGER NOT NULL DEFAULT 0 CHECK(typeof(corpus)='integer' AND corpus>=0),
                    review INTEGER NOT NULL DEFAULT 0 CHECK(typeof(review)='integer' AND review>=0),
                    progress INTEGER NOT NULL DEFAULT 0 CHECK(typeof(progress)='integer' AND progress>=0),
                    ownership INTEGER NOT NULL DEFAULT 0 CHECK(typeof(ownership)='integer' AND ownership>=0),
                    synchronization INTEGER NOT NULL DEFAULT 0 CHECK(typeof(synchronization)='integer' AND synchronization>=0)
                );
                INSERT OR IGNORE INTO notebook_change_clock(singleton,epoch) VALUES(1,lower(hex(randomblob(16))));
                """, errorContext: "Create notebook dependency clocks")
            for dependency in dependencies {
                try installTriggers(for: dependency, in: core)
            }
        }
    }

    static func isInstalled(in core: DatabaseCore) throws -> Bool {
        let names = dependencies.flatMap { dependency in
            ["insert", "update", "delete"].map { "notebook_clock_\(triggerVersion)_\(dependency.table)_\($0)" }
        }
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
        return try core.tableExists(name: "notebook_change_clock") &&
            core.scalarInt(sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN (\(placeholders))",
                           values: names.map(SQLiteValue.text)) == names.count
    }

    private static func installTriggers(for dependency: Dependency, in core: DatabaseCore) throws {
        let columns = try core.query(sql: "PRAGMA table_info(\(dependency.table))", values: []) {
            DatabaseCore.columnText(statement: $0, index: 1)
        }.filter { !dependency.ignoredUpdates.contains($0) }
        guard !columns.isEmpty else { throw LocalStoreError.database("Missing notebook dependency table: \(dependency.table)") }
        let changed = columns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
        let increments: [(NotebookChangeDomains, String)] = [(.corpus, "corpus"), (.review, "review"),
            (.progress, "progress"), (.ownership, "ownership"), (.synchronization, "synchronization")]
        let assignments = increments.filter { dependency.domains.contains($0.0) }
            .map { "\($0.1)=\($0.1)+1" }.joined(separator: ",")
        for event in ["insert", "update", "delete"] {
            let condition = event == "update" ? "WHEN \(changed)" : ""
            // UPDATE OF skips the trigger entirely for ACK-only columns, avoiding comparisons
            // of large saved audio/base64 payloads when only a transport flag changed.
            let operation = event == "update" ? "UPDATE OF \(columns.joined(separator: ","))" : event.uppercased()
            try core.executeScript(sql: """
                CREATE TRIGGER IF NOT EXISTS notebook_clock_\(triggerVersion)_\(dependency.table)_\(event)
                AFTER \(operation) ON \(dependency.table) \(condition) BEGIN
                    UPDATE notebook_change_clock SET \(assignments) WHERE singleton=1;
                END;
                """, errorContext: "Track notebook \(dependency.table) changes")
        }
    }
}

extension DatabaseCore {
    /// Call under the caller's SQL snapshot. Unlike PRAGMA data_version, these values describe
    /// the pinned WAL snapshot itself; a reader cannot stamp old rows with a future commit.
    func notebookChangeStamp() throws -> NotebookChangeStamp {
        let schema = try scalarInt(sql: "PRAGMA schema_version", values: [])
        if notebookChangeTrackingSchema?.version != schema {
            notebookChangeTrackingSchema = (schema, try NotebookChangeTracking.isInstalled(in: self))
        }
        let epoch: String
        let values: [Int64]
        if notebookChangeTrackingSchema?.installed == true {
            let row = try query(sql: "SELECT epoch,corpus,review,progress,ownership,synchronization FROM notebook_change_clock WHERE singleton=1",
                                values: []) { row in
                guard sqlite3_column_type(row, 0) == SQLITE_TEXT else { throw LocalStoreError.database("Invalid notebook clock epoch") }
                let counters = try (1...5).map { index -> Int64 in
                    guard sqlite3_column_type(row, Int32(index)) == SQLITE_INTEGER,
                          sqlite3_column_int64(row, Int32(index)) >= 0 else { throw LocalStoreError.database("Invalid notebook dependency clock") }
                    return sqlite3_column_int64(row, Int32(index))
                }
                return (DatabaseCore.columnText(statement: row, index: 0), counters)
            }.first
            guard let row, !row.0.isEmpty else { throw LocalStoreError.database("Missing notebook dependency clock") }
            (epoch, values) = row
        } else {
            // A read-only host may open an existing format before a writer installs metadata.
            // Retain broad invalidation there; opening a reader must never modify that database.
            epoch = "untracked-\(try scalarInt(sql: "PRAGMA data_version", values: []))"
            values = Array(repeating: sqlite3_total_changes64(connection), count: 5)
        }
        let tokens = values.map { NotebookChangeToken(schemaVersion: schema, epoch: epoch, value: $0) }
        return .init(corpus: tokens[0], review: tokens[1], progress: tokens[2], ownership: tokens[3], synchronization: tokens[4])
    }
}
