import LingroveNotebookPersistenceCodec
import LingroveNotebook
import Darwin
import Foundation

/// One archive actor owns this database for its lifetime. Relationships use foreign keys and
/// indexes; small typed payloads preserve rich formatting and review configuration without a
/// second interpretation of domain rules. Only changed rows are encoded and written in a commit.
public nonisolated final class VocabularySQLiteDatabase {
    typealias Row = VocabularyPersistenceRow
    typealias Value = VocabularySQLiteConnection.Value
    static let applicationID: Int64 = 0x4C47564E // LGVN, independent of the portable JSON schema.
    public static let schemaVersion: Int64 = 5
    let connection: VocabularySQLiteConnection
    private var fileLock: VocabularySQLiteFileLock?
    private(set) var lastWrittenRows = 0

    public init(url: URL?, onDiagnostic: (@Sendable (VocabularySQLiteDiagnostic) -> Void)? = nil) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) { try Self.create(at: url, onDiagnostic: onDiagnostic) }
            connection = try VocabularySQLiteConnection(url: url, onDiagnostic: onDiagnostic)
        } else {
            connection = try VocabularySQLiteConnection(url: nil, onDiagnostic: onDiagnostic)
            try Self.createSchema(connection)
        }
        fileLock = try VocabularySQLiteFileLock(database: url)
        try access(write: true) {
            guard try scalar("PRAGMA application_id") == Self.applicationID else { throw VocabularyError.invalidArchive }
            let version = try scalar("PRAGMA user_version")
            if version == 4 {
                try VocabularySQLiteClassificationSchema.migrate(connection)
            } else if version != Self.schemaVersion { throw VocabularyError.unsupportedVersion }
            guard try connection.rows("PRAGMA quick_check") == [[.text("ok")]],
                  try connection.rows("PRAGMA foreign_key_check").isEmpty else { throw VocabularyError.invalidArchive }
            // WAL lets snapshot readers coexist with the app's writer. FULL retains durable
            // acknowledgement; opening/reconfiguring a second instance uses the same lock.
            _ = try connection.rows("PRAGMA journal_mode=WAL")
            try connection.execute("PRAGMA synchronous=FULL")
        }
    }

    /// The owning archive uses this synchronous scope to keep media staging and its SQL write
    /// under one cross-process lock. It must not suspend or transfer this database to another
    /// executor inside the closure; nested reads are allowed, but reads cannot upgrade to writes.
    public func access<T>(write: Bool, _ operation: () throws -> T) throws -> T {
        guard let fileLock else { throw VocabularyError.invalidArchive }
        return try fileLock.access(write: write) {
            try connection.verifyFile()
            return try operation()
        }
    }

    public func revision() throws -> UInt64 {
        try connection.verifyFile()
        let value = try scalar("SELECT revision FROM state WHERE singleton=1")
        guard value >= 0 else { throw VocabularyError.invalidArchive }; return UInt64(value)
    }

    public func read() throws -> VocabularySnapshot {
        try access(write: false) { try readUnlocked() }
    }

    private func readUnlocked() throws -> VocabularySnapshot {
        try connection.transaction(write: false) {
            let revision = try self.revision(), hasTemplates = try scalar("SELECT has_templates FROM state WHERE singleton=1")
            guard hasTemplates == 0 || hasTemplates == 1 else { throw VocabularyError.invalidArchive }
            var records: [Row] = []
            for table in VocabularyPersistenceEntity.allCases {
                let columns = ["id", "parent_id", "position", "payload"] + table.extraColumns
                for values in try connection.rows("SELECT " + columns.joined(separator: ",") + " FROM " + table.rawValue) {
                    guard let id = values[0].string, let position = values[2].integer, position >= 0,
                          position <= Int64(Int.max), let data = values[3].data else { throw VocabularyError.invalidArchive }
                    let extra = values.dropFirst(4).map(\.string)
                    guard values.dropFirst(4).allSatisfy({ $0 == .null || $0.string != nil }),
                          values[1] == .null || values[1].string != nil else { throw VocabularyError.invalidArchive }
                    records.append(try .init(entity: table, id: id, parentID: values[1].string,
                        position: Int(position), payload: data,
                        indexValues: Dictionary(uniqueKeysWithValues: zip(table.indexKeys, extra))))
                }
            }
            return .init(revision: revision, document: try VocabularyPersistenceCodec.decode(.init(rows: records, reviewTemplatesPresent: hasTemplates == 1)))
        }
    }

    public func receipt(key: String) throws -> VocabularyCLIReceipt? {
        try access(write: false) {
            guard let row = try connection.rows("SELECT fingerprint,result FROM cli_receipts WHERE key=?", [.text(key)]).first else {
                return nil
            }
            guard let fingerprint = row[0].string, let data = row[1].data else { throw VocabularyError.invalidArchive }
            return .init(key: key, fingerprint: fingerprint, result: data)
        }
    }

    /// Persist an already normalized and validated candidate. The archive supplies the previous
    /// document from expectedRevision for row diffing; the transaction rejects a stale revision
    /// before applying those differences. This layer does not own catalog or media policy.
    public func write(_ next: VocabularyDocument, previous: VocabularyDocument, expectedRevision: UInt64,
               receipt: VocabularyCLIReceipt? = nil) throws -> UInt64 {
        try access(write: true) { try writeUnlocked(next, previous: previous, expectedRevision: expectedRevision, receipt: receipt) }
    }

    private func writeUnlocked(_ next: VocabularyDocument, previous: VocabularyDocument, expectedRevision: UInt64,
                               receipt: VocabularyCLIReceipt?) throws -> UInt64 {
        let oldRows = try VocabularyPersistenceCodec.encode(previous).keyedRows(), newRows = try VocabularyPersistenceCodec.encode(next).keyedRows()
        let changed = newRows.values.filter { oldRows[$0.key] != $0 }
        let removed = oldRows.values.filter { newRows[$0.key] == nil }
        let count = connection.totalChanges
        let revision = try connection.transaction(write: true) {
            guard try self.revision() == expectedRevision, expectedRevision < UInt64(Int64.max) else { throw VocabularyError.editConflict }
            // A restore can replace an entry with a different ID but the same expression key.
            // Release changed/deleted keys inside this transaction before installing new owners.
            for row in oldRows.values where row.entity == .entries && newRows[row.key]?.indexValue(.lookupKey) != row.indexValue(.lookupKey) {
                try connection.execute("UPDATE entries SET lookup_key=NULL WHERE id=?", [.text(row.id)])
            }
            // Preferred-name uniqueness is immediate. Release replaced labels before upserts,
            // allowing a language's preferred label to change atomically, in either row order.
            for row in oldRows.values where row.entity == .meaningLabels && newRows[row.key] != row {
                try connection.execute("UPDATE meaning_labels SET preferred='no' WHERE id=?", [.text(row.id)])
            }
            for table in VocabularyPersistenceEntity.allCases {
                for row in changed where row.entity == table { try upsert(row) }
            }
            // Reparent usages/cards before deleting old owners; cascades cannot erase a move.
            for table in VocabularyPersistenceEntity.allCases.reversed() {
                for row in removed where row.entity == table {
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
        let columns = ["id", "parent_id", "position", "payload"] + row.entity.extraColumns
        let update = columns.dropFirst().map { $0 + "=excluded." + $0 }.joined(separator: ",")
        let sql = "INSERT INTO " + row.entity.rawValue + " (" + columns.joined(separator: ",") + ") VALUES (" +
            Array(repeating: "?", count: columns.count).joined(separator: ",") + ") ON CONFLICT(id) DO UPDATE SET " + update
        try connection.execute(sql, [.text(row.id), row.parentID.map(Value.text) ?? .null,
            .integer(Int64(row.position)), .blob(try row.encodedPayload())] + row.entity.indexKeys.map { row.indexValue($0).map(Value.text) ?? .null })
    }

    /// Publish a fully initialized, closed database with an exclusive hard link. A crash cannot
    /// expose half a schema, and a second launch that wins the race is never overwritten.
    private static func create(at destination: URL, onDiagnostic: (@Sendable (VocabularySQLiteDiagnostic) -> Void)?) throws {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".vocabulary-" + UUID().uuidString + ".sqlite")
        defer {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: staged.path + suffix))
            }
        }
        let connection = try VocabularySQLiteConnection(url: staged, create: true, onDiagnostic: onDiagnostic)
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
            for table in VocabularyPersistenceEntity.allCases {
                let parent = table.parent.map { "TEXT NOT NULL REFERENCES " + $0.rawValue +
                    "(id) DEFERRABLE INITIALLY DEFERRED" } ?? "TEXT CHECK(parent_id IS NULL)"
                let extra: String
                switch table {
                case .entries: extra = ",lookup_key TEXT UNIQUE,language TEXT NOT NULL,expression TEXT NOT NULL"
                case .senses: extra = ",meaning TEXT NOT NULL"
                default: extra = VocabularySQLiteMeaningSchema.columns(table)
                }
                try connection.execute("CREATE TABLE " + table.rawValue + " (id TEXT PRIMARY KEY NOT NULL,parent_id " + parent +
                    ",position INTEGER NOT NULL CHECK(position>=0),payload BLOB NOT NULL" + extra + ")")
                try connection.execute("CREATE INDEX " + table.rawValue + "_owner ON " + table.rawValue + "(parent_id,position)")
            }
            try connection.execute("CREATE INDEX entries_language ON entries(language,expression)")
            try VocabularySQLiteMeaningSchema.createIndexes(connection)
            try VocabularySQLiteClassificationSchema.createIndexes(connection)
            try createReceiptTable(connection)
            try connection.execute("PRAGMA application_id=" + String(applicationID))
            try connection.execute("PRAGMA user_version=" + String(schemaVersion))
        }
    }

    private static func createReceiptTable(_ connection: VocabularySQLiteConnection) throws {
        try connection.execute("CREATE TABLE cli_receipts (key TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, result BLOB NOT NULL)")
    }
}

/// SQL identifiers remain a store concern. The codec supplies only a fixed typed index set;
/// user text is still passed as a bound SQLite value rather than interpolated into identifiers.
private extension VocabularyPersistenceEntity {
    var extraColumns: [String] { indexKeys.map(\.rawValue) }
}
