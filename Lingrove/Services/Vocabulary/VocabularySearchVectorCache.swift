import Foundation
import LingroveNotebookEngine
import SQLite3

/// The search actor owns this disposable cache, separate from the canonical notebook database.
/// Exact text fingerprints identify immutable vectors. SQLite commits row deltas, avoiding an
/// entire floating-point JSON rewrite for one edit. No source text or account credentials enter it.
nonisolated final class VocabularySearchVectorCache {
    private let url: URL
    private let model: String
    private let dimensions: Int
    private let maximumRows: Int
    private let maximumBytes = 256 * 1_024 * 1_024
    private var persistedKeys: Set<String> = []

    init(url: URL, model: String, dimensions: Int, maximumRows: Int = 49_152) {
        precondition(dimensions > 0 && dimensions <= 4096 && maximumRows > 0)
        self.url = url; self.model = model; self.dimensions = dimensions; self.maximumRows = maximumRows
    }

    func load() throws -> [String: [Float]] {
        do {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes { throw invalidCache() }
            let core = try open(); defer { try? core.close() }
            var invalid = Set<String>()
            let rows = try core.query(sql: "SELECT fingerprint,vector FROM search_vectors LIMIT ?",
                values: [.integer(Int64(maximumRows + 1))]) { statement -> (String, [Float]?) in
                let key = DatabaseCore.columnText(statement: statement, index: 0)
                guard validKey(key), sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                      Int(sqlite3_column_bytes(statement, 1)) == dimensions * 4,
                      let bytes = sqlite3_column_blob(statement, 1) else { return (key, nil) }
                // Copy the statement-owned buffer before stepping/finalizing it. Decoding uses
                // unaligned little-endian loads, so SQLite's pointer alignment is never assumed.
                return (key, decode(Data(bytes: bytes, count: dimensions * 4)))
            }
            guard rows.count <= maximumRows else { throw invalidCache() }
            var result: [String: [Float]] = [:]
            for (key, vector) in rows {
                if let vector { result[key] = vector } else { invalid.insert(key) }
            }
            try core.inTransaction {
                for key in invalid { try core.execute(sql: "DELETE FROM search_vectors WHERE fingerprint=?", values: [.text(key)]) }
            }
            persistedKeys = Set(result.keys)
            return result
        } catch {
            // Only this explicitly supplied derived-cache path is removed. A corrupt cache
            // must be rebuildable on the next successful reconcile, without touching corpus IO.
            remove()
            throw error
        }
    }

    @discardableResult
    func save(_ vectors: [String: [Float]]) throws -> Int {
        let keys: Set<String>
        if vectors.count > maximumRows {
            keys = Set(vectors.keys.sorted().prefix(maximumRows))
        } else {
            keys = Set(vectors.keys)
        }
        let removed = persistedKeys.subtracting(keys), added = keys.subtracting(persistedKeys)
        guard !removed.isEmpty || !added.isEmpty else { return 0 }
        let core = try open(); defer { try? core.close() }
        try core.inTransaction {
            for key in removed { try core.execute(sql: "DELETE FROM search_vectors WHERE fingerprint=?", values: [.text(key)]) }
            for key in added {
                guard validKey(key), let vector = vectors[key], valid(vector) else { throw invalidCache() }
                try core.execute(sql: "INSERT OR REPLACE INTO search_vectors(fingerprint,vector) VALUES(?,?)",
                    values: [.text(key), .blob(encode(vector))])
            }
        }
        persistedKeys = keys
        return removed.count + added.count
    }

    func remove() {
        persistedKeys = []
        for path in [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] {
            try? FileManager.default.removeItem(at: path)
        }
    }

    private func open() throws -> DatabaseCore {
        let core = try DatabaseCore(databaseURL: url, mediaDirectoryURL: url.deletingLastPathComponent()) { _ in nil }
        do {
            // The row cap bounds normal writes; SQLite's page cap also refuses unexpectedly
            // large files. WAL can temporarily hold another transaction's bounded page set.
            let pageSize = try core.scalarInt(sql: "PRAGMA page_size", values: [])
            guard pageSize > 0 else { throw invalidCache() }
            try core.executeScript(sql: "PRAGMA max_page_count=\(maximumBytes / pageSize);", errorContext: "Bound search cache pages")
            try core.inTransaction {
                try core.executeScript(sql: """
                    CREATE TABLE IF NOT EXISTS search_cache_model(
                        singleton INTEGER PRIMARY KEY CHECK(singleton=1),identity TEXT NOT NULL,dimensions INTEGER NOT NULL);
                    CREATE TABLE IF NOT EXISTS search_vectors(fingerprint TEXT PRIMARY KEY,vector BLOB NOT NULL);
                    """, errorContext: "Create derived vector cache")
                let matches = try core.scalarInt(sql:
                    "SELECT COUNT(*) FROM search_cache_model WHERE singleton=1 AND identity=? AND dimensions=?",
                    values: [.text(model), .integer(Int64(dimensions))]) == 1
                if !matches {
                    try core.execute(sql: "DELETE FROM search_vectors", values: [])
                    try core.execute(sql: "INSERT OR REPLACE INTO search_cache_model(singleton,identity,dimensions) VALUES(1,?,?)",
                        values: [.text(model), .integer(Int64(dimensions))])
                    persistedKeys = []
                }
            }
            return core
        } catch { try? core.close(); throw error }
    }

    private func encode(_ vector: [Float]) -> Data {
        var bytes = Data(capacity: vector.count * 4)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    private func decode(_ bytes: Data) -> [Float]? {
        let values = bytes.withUnsafeBytes { raw in
            (0..<dimensions).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        return valid(values) ? values : nil
    }

    private func valid(_ vector: [Float]) -> Bool {
        vector.count == dimensions && vector.allSatisfy(\.isFinite) && abs(vector.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.01
    }
    private func validKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func invalidCache() -> CocoaError { .init(.fileReadCorruptFile) }
}
