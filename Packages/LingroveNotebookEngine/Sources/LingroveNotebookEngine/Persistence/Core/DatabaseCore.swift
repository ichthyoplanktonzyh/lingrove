import Foundation
import SQLite3

public enum SQLiteValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
}

public let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
public let defaultSchedulerAlgorithm: String = defaultSchedulerSettingsConfig.algorithm

public final class DatabaseCore {
    public let databaseURL: URL
    /// The Core owns this handle. Production callers use its guarded methods; internal visibility
    /// preserves the existing native-mutex integration probes, which run only while it is open.
    let connection: OpaquePointer
    public let encoder: JSONEncoder
    public let decoder: JSONDecoder
    /// Workspace id inserted when initialization bootstrapped the first local
    /// workspace row on a brand-new device, and `nil` otherwise — including
    /// after `resetForAccountDeletion()`, which recreates the workspace on a
    /// device that is not new.
    public private(set) var createdDefaultWorkspaceId: String?
    private var isClosed: Bool
    /// SQLite's own mutex dies with the connection, so it cannot protect a caller arriving after
    /// close. This longer-lived lock serializes native access with close. It is recursive because
    /// transactions call the same query/execute methods while already holding connection ownership.
    private let connectionLock = NSRecursiveLock()

    public let mediaDirectoryURL: URL
    public var diagnostics: ((NotebookStorageDiagnostic) -> Void)?

    /// Hosts provide their own schema/bootstrap callback while sharing the same guarded handle.
    /// The callback runs synchronously before this connection can escape to another owner.
    public init(databaseURL: URL, mediaDirectoryURL: URL,
                initialize: (DatabaseCore) throws -> String?) throws {
        self.databaseURL = databaseURL
        self.mediaDirectoryURL = mediaDirectoryURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.createdDefaultWorkspaceId = nil
        self.isClosed = false
        try Self.prepareMediaDirectory(mediaDirectoryURL)
        self.connection = try Self.openConnection(databaseURL: databaseURL)
        sqlite3_busy_timeout(self.connection, 5_000)
        try self.enableForeignKeys()
        try self.enableWriteAheadLogging()
        self.createdDefaultWorkspaceId = try initialize(self)
    }

    public func clearDefaultWorkspaceCreationSignal() { self.createdDefaultWorkspaceId = nil }

    deinit {
        if self.isClosed == false {
            sqlite3_close_v2(self.connection)
        }
    }

    public func close() throws {
        self.connectionLock.lock()
        defer { self.connectionLock.unlock() }
        guard self.isClosed == false else {
            return
        }

        let closeResult = sqlite3_close_v2(self.connection)
        guard closeResult == SQLITE_OK else {
            throw LocalStoreError.database("Failed to close database connection: \(self.lastErrorMessage())")
        }

        self.isClosed = true
    }

    public func encodeJsonString<T: Encodable>(value: T) throws -> String {
        let data = try self.encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalStoreError.database("Failed to encode JSON payload")
        }

        return json
    }

    @discardableResult
    public func execute(sql: String, values: [SQLiteValue]) throws -> Int {
        self.connectionLock.lock()
        defer { self.connectionLock.unlock() }
        try self.requireOpenConnection()
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw LocalStoreError.database("Failed to prepare statement: \(self.lastErrorMessage())")
        }
        defer {
            sqlite3_finalize(statement)
        }

        try self.bind(values: values, to: statement)
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE else {
            throw LocalStoreError.database("Failed to execute statement: \(self.lastErrorMessage())")
        }

        return Int(sqlite3_changes(connection))
    }

    public func query<T>(
        sql: String,
        values: [SQLiteValue],
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        self.connectionLock.lock()
        defer { self.connectionLock.unlock() }
        try self.requireOpenConnection()
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw LocalStoreError.database("Failed to prepare query: \(self.lastErrorMessage())")
        }
        defer {
            sqlite3_finalize(statement)
        }

        try self.bind(values: values, to: statement)

        var rows: [T] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                rows.append(try map(statement))
                continue
            }

            if stepResult == SQLITE_DONE {
                break
            }

            throw LocalStoreError.database("Failed to execute query: \(self.lastErrorMessage())")
        }

        return rows
    }

    public func scalarInt(sql: String, values: [SQLiteValue]) throws -> Int {
        let results = try self.query(sql: sql, values: values) { statement in
            Int(Self.columnInt64(statement: statement, index: 0))
        }

        guard let value = results.first else {
            throw LocalStoreError.database("Expected an integer result for SQL query")
        }

        return value
    }

    public func scalarText(sql: String, values: [SQLiteValue]) throws -> String {
        let results = try self.query(sql: sql, values: values) { statement in
            Self.columnText(statement: statement, index: 0)
        }

        guard let value = results.first else {
            throw LocalStoreError.database("Expected a text result for SQL query")
        }

        return value
    }

    public func scalarOptionalText(sql: String, values: [SQLiteValue]) throws -> String? {
        let results = try self.query(sql: sql, values: values) { statement in
            Self.columnOptionalText(statement: statement, index: 0)
        }

        guard let value = results.first else {
            throw LocalStoreError.database("Expected an optional text result for SQL query")
        }

        return value
    }

    public func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try self.runTransaction(beginStatement: "BEGIN IMMEDIATE TRANSACTION", body)
    }

    public func inReadTransaction<T>(_ body: () throws -> T) throws -> T {
        try self.runTransaction(beginStatement: "BEGIN DEFERRED TRANSACTION", body)
    }

    private func runTransaction<T>(
        beginStatement: String,
        _ body: () throws -> T
    ) throws -> T {
        self.connectionLock.lock()
        defer { self.connectionLock.unlock() }
        try self.requireOpenConnection()
        guard let mutex = sqlite3_db_mutex(connection) else {
            throw LocalStoreError.database("Failed to begin transaction: SQLite connection mutex is unavailable")
        }
        sqlite3_mutex_enter(mutex)
        defer {
            sqlite3_mutex_leave(mutex)
        }

        let beginResult = sqlite3_exec(connection, beginStatement, nil, nil, nil)
        guard beginResult == SQLITE_OK else {
            throw LocalStoreError.database("Failed to begin transaction: \(self.lastErrorMessage())")
        }

        do {
            let result = try body()
            let commitResult = sqlite3_exec(connection, "COMMIT TRANSACTION", nil, nil, nil)
            guard commitResult == SQLITE_OK else {
                throw LocalStoreError.database("Failed to commit transaction: \(self.lastErrorMessage())")
            }
            return result
        } catch {
            sqlite3_exec(connection, "ROLLBACK TRANSACTION", nil, nil, nil)
            throw error
        }
    }


    public static func columnText(statement: OpaquePointer, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            return ""
        }

        // SQLite text can contain an embedded NUL. Copy its exact byte span while the
        // statement owns the pointer; C-string decoding would silently truncate notebook indexes.
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: value, count: count), as: UTF8.self)
    }

    public static func columnOptionalText(statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return self.columnText(statement: statement, index: index)
    }

    public static func columnInt64(statement: OpaquePointer, index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    public static func columnDouble(statement: OpaquePointer, index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    public static func columnOptionalInt(statement: OpaquePointer, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return Int(self.columnInt64(statement: statement, index: index))
    }

    public static func columnOptionalDouble(statement: OpaquePointer, index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return sqlite3_column_double(statement, index)
    }

    public func executeScript(sql: String, errorContext: String) throws {
        self.connectionLock.lock()
        defer { self.connectionLock.unlock() }
        try self.requireOpenConnection()
        let resultCode = sqlite3_exec(connection, sql, nil, nil, nil)
        guard resultCode == SQLITE_OK else {
            throw LocalStoreError.database("\(errorContext): \(self.lastErrorMessage())")
        }
    }

    public func tableExists(name: String) throws -> Bool {
        let rows = try self.query(
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            values: [.text(name)]
        ) { statement in
            Self.columnText(statement: statement, index: 0)
        }

        return rows.isEmpty == false
    }

    public func columnExists(tableName: String, columnName: String) throws -> Bool {
        let columns = try self.query(
            sql: "PRAGMA table_info(\(tableName))",
            values: []
        ) { statement in
            Self.columnText(statement: statement, index: 1)
        }

        return columns.contains(columnName)
    }


    /// An injected media root may differ from the SQL directory. Establish it once before
    /// stores publish children, and refuse a symlink at the capability boundary itself.
    private static func prepareMediaDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LocalStoreError.database("Media directory must be a real directory")
        }
    }

    private static func openConnection(databaseURL: URL) throws -> OpaquePointer {
        let parentDirectory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let resultCode = sqlite3_open_v2(databaseURL.path, &connection, flags, nil)

        guard resultCode == SQLITE_OK, let connection else {
            let message = connection.map { openConnection in
                String(cString: sqlite3_errmsg(openConnection))
            } ?? "Unknown SQLite open error"
            if let connection {
                sqlite3_close(connection)
            }
            throw LocalStoreError.database("Failed to open local database: \(message)")
        }

        return connection
    }

    private func enableForeignKeys() throws {
        try self.executeScript(
            sql: "PRAGMA foreign_keys = ON;",
            errorContext: "Failed to enable SQLite foreign keys"
        )
    }

    private func enableWriteAheadLogging() throws {
        let journalMode = try self.scalarText(sql: "PRAGMA journal_mode = WAL;", values: [])
        if journalMode.lowercased() != "wal" {
            throw LocalStoreError.database("Failed to enable SQLite WAL mode: received \(journalMode)")
        }
    }

    private func bind(values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)

            switch value {
            case .integer(let integer):
                guard sqlite3_bind_int64(statement, index, integer) == SQLITE_OK else {
                    throw LocalStoreError.database("Failed to bind integer parameter at index \(offset)")
                }
            case .real(let real):
                guard sqlite3_bind_double(statement, index, real) == SQLITE_OK else {
                    throw LocalStoreError.database("Failed to bind real parameter at index \(offset)")
                }
            case .text(let text):
                let count = text.utf8.count
                guard count <= Int(Int32.max) else {
                    throw LocalStoreError.database("Text parameter is too large")
                }
                // SQLITE_TRANSIENT copies these bytes before withCString releases its buffer.
                // An explicit length preserves embedded NULs in source text and index values.
                let result = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(count), sqliteTransient) }
                guard result == SQLITE_OK else {
                    throw LocalStoreError.database("Failed to bind text parameter at index \(offset)")
                }
            case .null:
                guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                    throw LocalStoreError.database("Failed to bind null parameter at index \(offset)")
                }
            }
        }
    }

    private func lastErrorMessage() -> String {
        self.connectionLock.lock()
        defer { self.connectionLock.unlock() }
        guard self.isClosed == false else { return "Database connection is closed" }
        return String(cString: sqlite3_errmsg(connection))
    }

    /// Every native entry holds connectionLock before this check and through its final C call.
    /// Late cancelled UI tasks receive a recoverable error instead of touching a freed SQLite mutex.
    private func requireOpenConnection() throws {
        guard self.isClosed == false else {
            throw LocalStoreError.database("Database connection is closed")
        }
    }
}
