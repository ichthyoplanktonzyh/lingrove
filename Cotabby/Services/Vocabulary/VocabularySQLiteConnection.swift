import Darwin
import Foundation
import Logging
import SQLite3

/// A non-Sendable connection belongs exclusively to VocabularyArchive's actor. Synchronous
/// calls never suspend while a statement or transaction is live. This file confines borrowed
/// C pointers, parameter binding and file-identity checks; callers only exchange Swift values.
nonisolated final class VocabularySQLiteConnection {
    enum Value: Equatable {
        case text(String), integer(Int64), blob(Data), null
        var string: String? { if case let .text(value) = self { value } else { nil } }
        var integer: Int64? { if case let .integer(value) = self { value } else { nil } }
        var data: Data? { if case let .blob(value) = self { value } else { nil } }
    }
    private var handle: OpaquePointer?
    private let url: URL?
    private let identity: (device: dev_t, inode: ino_t)?

    init(url: URL?, create: Bool = false) throws {
        self.url = url
        if let url, create {
            let file = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard file >= 0 else { throw VocabularyError.invalidArchive }; Darwin.close(file)
        }
        var info = stat()
        if let url {
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw VocabularyError.invalidArchive }
            identity = (info.st_dev, info.st_ino)
        } else { identity = nil }
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW | (url == nil ? SQLITE_OPEN_CREATE : 0)
        // Foundation deliberately rewrites /private/var back to /var, even after
        // resolvingSymlinksInPath(). SQLite's NOFOLLOW rejects that system alias. Use
        // POSIX realpath for the parent only; keep the leaf so NOFOLLOW still rejects
        // a database symlink introduced between our lstat and sqlite3_open_v2.
        let path: String
        if let url {
            guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw VocabularyError.invalidArchive }
            defer { free(parent) }
            path = String(cString: parent) + "/" + url.lastPathComponent
        } else { path = ":memory:" }
        let status = sqlite3_open_v2(path, &pointer, flags, nil)
        guard status == SQLITE_OK, let pointer else {
            CotabbyLogger.learning.error("Vocabulary SQLite connection failed", metadata: ["sqlite_code": .stringConvertible(status)])
            if let pointer { sqlite3_close_v2(pointer) }; throw VocabularyError.invalidArchive
        }
        handle = pointer
        sqlite3_busy_timeout(pointer, 2_000)
        sqlite3_limit(pointer, SQLITE_LIMIT_LENGTH, 64 * 1_024 * 1_024)
        do { try verifyFile(); try execute("PRAGMA foreign_keys=ON") } catch { close(); throw error }
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }
    func close() { if let handle { sqlite3_close_v2(handle); self.handle = nil } }

    /// A replaced/unlinked open database can still accept writes through its descriptor. Refuse
    /// that detached file so a successful UI save always corresponds to the named notebook.
    func verifyFile() throws {
        guard let url, let identity else { return }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == identity.device, info.st_ino == identity.inode else { throw VocabularyError.invalidArchive }
    }

    var totalChanges: Int { handle.map { Int(sqlite3_total_changes($0)) } ?? 0 }

    func transaction<T>(write: Bool, _ body: () throws -> T) throws -> T {
        try verifyFile()
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func execute(_ sql: String, _ values: [Value] = []) throws { _ = try rows(sql, values) }

    func rows(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        guard let handle else { throw VocabularyError.invalidArchive }
        var pointer: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &pointer, nil))
        guard let statement = pointer else { throw VocabularyError.invalidArchive }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == values.count else { throw VocabularyError.invalidContent }
        for (index, value) in values.enumerated() { try bind(value, index: Int32(index + 1), statement: statement) }
        var result: [[Value]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            try check(status)
            guard status == SQLITE_ROW else { throw VocabularyError.invalidArchive }
            result.append(try (0..<sqlite3_column_count(statement)).map { try column($0, statement: statement) })
        }
    }

    private func bind(_ value: Value, index: Int32, statement: OpaquePointer) throws {
        // SQLITE_TRANSIENT asks SQLite to copy before the Swift buffer's borrow ends. -1 is
        // SQLite's documented destructor sentinel, not a function pointer we ever invoke.
        let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status: Int32
        switch value {
        case .null: status = sqlite3_bind_null(statement, index)
        case let .integer(number): status = sqlite3_bind_int64(statement, index, number)
        case let .text(text):
            guard text.utf8.count <= 64 * 1_024 * 1_024 else { throw VocabularyError.oversizedArchive }
            status = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), copy) }
        case let .blob(data):
            guard data.count <= 64 * 1_024 * 1_024 else { throw VocabularyError.oversizedArchive }
            if data.isEmpty { status = sqlite3_bind_zeroblob(statement, index, 0) } else {
                status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), copy) }
            }
        }
        try check(status)
    }

    private func column(_ index: Int32, statement: OpaquePointer) throws -> Value {
        let count = Int(sqlite3_column_bytes(statement, index))
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_TEXT:
            guard let bytes = sqlite3_column_text(statement, index),
                  let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else {
                throw VocabularyError.invalidArchive
            }
            return .text(value)
        case SQLITE_BLOB:
            if count == 0 { return .blob(Data()) }
            guard let bytes = sqlite3_column_blob(statement, index) else { throw VocabularyError.invalidArchive }
            return .blob(Data(bytes: bytes, count: count))
        default: throw VocabularyError.invalidArchive
        }
    }

    private func check(_ code: Int32) throws {
        guard code != SQLITE_OK, code != SQLITE_ROW, code != SQLITE_DONE else { return }
        CotabbyLogger.learning.error("Vocabulary SQLite operation failed", metadata: ["sqlite_code": .stringConvertible(code)])
        if code == SQLITE_BUSY || code == SQLITE_LOCKED { throw VocabularyError.storageBusy }
        throw VocabularyError.invalidArchive
    }
}
