import Darwin
import Foundation

/// One archive actor owns this database for its lifetime. Relationships use foreign keys and
/// indexes; small typed payloads preserve rich formatting and review configuration without a
/// second interpretation of domain rules. Only changed rows are encoded and written in a commit.
nonisolated final class VocabularySQLiteDatabase {
    typealias Row = VocabularyDatabaseRecord
    typealias Value = VocabularySQLiteConnection.Value
    static let applicationID: Int64 = 0x4C47564E // LGVN, independent of the portable JSON schema.
    static let schemaVersion: Int64 = 2
    let connection: VocabularySQLiteConnection
    private var fileLock: VocabularySQLiteFileLock?
    private(set) var lastWrittenRows = 0

    init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) { try Self.create(at: url) }
            connection = try VocabularySQLiteConnection(url: url)
        } else {
            connection = try VocabularySQLiteConnection(url: nil)
            try Self.createSchema(connection)
        }
        fileLock = try VocabularySQLiteFileLock(database: url)
        try access(write: true) {
            guard try scalar("PRAGMA application_id") == Self.applicationID else { throw VocabularyError.invalidArchive }
            let version = try scalar("PRAGMA user_version")
            guard version == 1 || version == Self.schemaVersion else { throw VocabularyError.unsupportedVersion }
            guard try connection.rows("PRAGMA quick_check") == [[.text("ok")]],
                  try connection.rows("PRAGMA foreign_key_check").isEmpty else { throw VocabularyError.invalidArchive }
            if version == 1 {
                // This upgrades the already accepted SQLite store, preserving its contents.
                // Retired JSON libraries are still never read or migrated.
                try connection.transaction(write: true) {
                    try Self.createReceiptTable(connection)
                    try connection.execute("PRAGMA user_version=" + String(Self.schemaVersion))
                }
            }
            // WAL lets snapshot readers coexist with the app's writer. FULL retains durable
            // acknowledgement; opening/reconfiguring a second instance uses the same lock.
            _ = try connection.rows("PRAGMA journal_mode=WAL")
            try connection.execute("PRAGMA synchronous=FULL")
        }
    }

    func access<T>(write: Bool, _ operation: () throws -> T) throws -> T {
        guard let fileLock else { throw VocabularyError.invalidArchive }
        return try fileLock.access(write: write) {
            try connection.verifyFile()
            return try operation()
        }
    }

    func revision() throws -> UInt64 {
        try connection.verifyFile()
        let value = try scalar("SELECT revision FROM state WHERE singleton=1")
        guard value >= 0 else { throw VocabularyError.invalidArchive }; return UInt64(value)
    }

    func read() throws -> VocabularySnapshot {
        try access(write: false) { try readUnlocked() }
    }

    private func readUnlocked() throws -> VocabularySnapshot {
        try connection.transaction(write: false) {
            let revision = try self.revision(), hasTemplates = try scalar("SELECT has_templates FROM state WHERE singleton=1")
            guard hasTemplates == 0 || hasTemplates == 1 else { throw VocabularyError.invalidArchive }
            var records: [Row] = []
            for table in Row.Table.allCases {
                let columns = ["id", "parent_id", "position", "payload"] + table.extraColumns
                for values in try connection.rows("SELECT " + columns.joined(separator: ",") + " FROM " + table.rawValue) {
                    guard let id = values[0].string, let position = values[2].integer, position >= 0,
                          position <= Int64(Int.max), let data = values[3].data else { throw VocabularyError.invalidArchive }
                    let payload: Row.Payload
                    do { payload = try .decode(data, table: table) } catch { throw VocabularyError.invalidArchive }
                    let extra = values.dropFirst(4).compactMap(\.string)
                    guard extra.count == table.extraColumns.count,
                          values[1] == .null || values[1].string != nil else { throw VocabularyError.invalidArchive }
                    records.append(.init(table: table, id: id, parentID: values[1].string,
                        position: Int(position), payload: payload, extra: extra))
                }
            }
            return .init(revision: revision, document: try VocabularyDatabaseProjection.document(records, hasTemplates: hasTemplates == 1))
        }
    }

    func receipt(key: String) throws -> VocabularyCLIReceipt? {
        try access(write: false) {
            guard let row = try connection.rows("SELECT fingerprint,result FROM cli_receipts WHERE key=?", [.text(key)]).first else { return nil }
            guard let fingerprint = row[0].string, let data = row[1].data else { throw VocabularyError.invalidArchive }
            return .init(key: key, fingerprint: fingerprint, result: data)
        }
    }

    func write(_ next: VocabularyDocument, previous: VocabularyDocument, expectedRevision: UInt64,
               receipt: VocabularyCLIReceipt? = nil) throws -> UInt64 {
        try access(write: true) { try writeUnlocked(next, previous: previous, expectedRevision: expectedRevision, receipt: receipt) }
    }

    private func writeUnlocked(_ next: VocabularyDocument, previous: VocabularyDocument, expectedRevision: UInt64,
                               receipt: VocabularyCLIReceipt?) throws -> UInt64 {
        let oldRows = try VocabularyDatabaseProjection.rows(previous), newRows = try VocabularyDatabaseProjection.rows(next)
        let changed = newRows.values.filter { oldRows[$0.key] != $0 }
        let removed = oldRows.values.filter { newRows[$0.key] == nil }
        let count = connection.totalChanges
        let revision = try connection.transaction(write: true) {
            guard try self.revision() == expectedRevision, expectedRevision < UInt64(Int64.max) else { throw VocabularyError.editConflict }
            // A restore can replace an entry with a different ID but the same expression key.
            // Release changed/deleted keys inside this transaction before installing new owners.
            for row in oldRows.values where row.table == .entries && newRows[row.key]?.extra.first != row.extra.first {
                try connection.execute("UPDATE entries SET lookup_key=NULL WHERE id=?", [.text(row.id)])
            }
            for table in Row.Table.allCases {
                for row in changed where row.table == table { try upsert(row) }
            }
            // Reparent usages/cards before deleting old owners; cascades cannot erase a move.
            for table in Row.Table.allCases.reversed() {
                for row in removed where row.table == table {
                    try connection.execute("DELETE FROM " + table.rawValue + " WHERE id=?", [.text(row.id)])
                }
            }
            let nextRevision = expectedRevision + 1
            if let receipt {
                try connection.execute("INSERT INTO cli_receipts (key,fingerprint,result) VALUES (?,?,?)",
                    [.text(receipt.key), .text(receipt.fingerprint), .blob(receipt.result)])
            }
            try connection.execute("UPDATE state SET revision=?,has_templates=? WHERE singleton=1",
                [.integer(Int64(nextRevision)), .integer(next.reviewTemplates == nil ? 0 : 1)])
            return nextRevision
        }
        lastWrittenRows = connection.totalChanges - count
        return revision
    }

    private func scalar(_ sql: String) throws -> Int64 {
        guard let value = try connection.rows(sql).first?.first?.integer else { throw VocabularyError.invalidArchive }; return value
    }

    private func upsert(_ row: Row) throws {
        let columns = ["id", "parent_id", "position", "payload"] + row.table.extraColumns
        let update = columns.dropFirst().map { $0 + "=excluded." + $0 }.joined(separator: ",")
        let sql = "INSERT INTO " + row.table.rawValue + " (" + columns.joined(separator: ",") + ") VALUES (" +
            Array(repeating: "?", count: columns.count).joined(separator: ",") + ") ON CONFLICT(id) DO UPDATE SET " + update
        try connection.execute(sql, [.text(row.id), row.parentID.map(Value.text) ?? .null,
            .integer(Int64(row.position)), .blob(try row.payload.encoded())] + row.extra.map(Value.text))
    }

    /// Publish a fully initialized, closed database with an exclusive hard link. A crash cannot
    /// expose half a schema, and a second launch that wins the race is never overwritten.
    private static func create(at destination: URL) throws {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".vocabulary-" + UUID().uuidString + ".sqlite")
        defer {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: staged.path + suffix))
            }
        }
        let connection = try VocabularySQLiteConnection(url: staged, create: true)
        defer { connection.close() }
        try createSchema(connection)
        connection.close()
        guard Darwin.link(staged.path, destination.path) == 0 || errno == EEXIST else { throw VocabularyError.invalidArchive }
    }

    private static func createSchema(_ connection: VocabularySQLiteConnection) throws {
        try connection.execute("PRAGMA synchronous=FULL")
        try connection.transaction(write: true) {
            try connection.execute("CREATE TABLE state (singleton INTEGER PRIMARY KEY CHECK(singleton=1), " +
                "revision INTEGER NOT NULL CHECK(revision>=0), has_templates INTEGER NOT NULL CHECK(has_templates IN (0,1)))")
            try connection.execute("INSERT INTO state VALUES (1,0,0)")
            for table in Row.Table.allCases {
                let parent = table.parent.map { "TEXT NOT NULL REFERENCES " + $0.rawValue +
                    "(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED" } ?? "TEXT CHECK(parent_id IS NULL)"
                let extra: String
                switch table {
                case .entries: extra = ",lookup_key TEXT UNIQUE,language TEXT NOT NULL,expression TEXT NOT NULL"
                case .senses: extra = ",meaning TEXT NOT NULL"
                default: extra = ""
                }
                try connection.execute("CREATE TABLE " + table.rawValue + " (id TEXT PRIMARY KEY NOT NULL,parent_id " + parent +
                    ",position INTEGER NOT NULL CHECK(position>=0),payload BLOB NOT NULL" + extra + ")")
                try connection.execute("CREATE INDEX " + table.rawValue + "_owner ON " + table.rawValue + "(parent_id,position)")
            }
            try connection.execute("CREATE INDEX entries_language ON entries(language,expression)")
            try createReceiptTable(connection)
            try connection.execute("PRAGMA application_id=" + String(applicationID))
            try connection.execute("PRAGMA user_version=" + String(schemaVersion))
        }
    }

    private static func createReceiptTable(_ connection: VocabularySQLiteConnection) throws {
        try connection.execute("CREATE TABLE cli_receipts (key TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, result BLOB NOT NULL)")
    }
}
