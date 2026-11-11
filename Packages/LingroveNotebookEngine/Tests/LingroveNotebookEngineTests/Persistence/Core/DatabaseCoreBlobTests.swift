import Foundation
import SQLite3
import Testing
@testable import LingroveNotebookEngine

struct DatabaseCoreBlobTests {
    @Test func binaryBindingsPreserveNulsAndDistinguishEmptyBlobFromNull() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-binary-sql-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try DatabaseCore(databaseURL: directory.appendingPathComponent("cache.sqlite"), mediaDirectoryURL: directory) { core in
            try core.executeScript(sql: "CREATE TABLE binary_values(id INTEGER PRIMARY KEY,bytes BLOB);", errorContext: "Create binary fixture")
            return nil
        }
        defer { try? core.close() }
        let binary = Data([0, 1, 0, 255, 128])
        try core.execute(sql: "INSERT INTO binary_values VALUES(1,?),(2,?),(3,?)", values: [.blob(binary), .blob(Data()), .null])
        let values = try core.query(sql: "SELECT typeof(bytes),bytes FROM binary_values ORDER BY id", values: []) { statement -> (String, Data) in
            let count = Int(sqlite3_column_bytes(statement, 1))
            let bytes = count == 0 ? Data() : Data(bytes: try #require(sqlite3_column_blob(statement, 1)), count: count)
            return (DatabaseCore.columnText(statement: statement, index: 0), bytes)
        }
        #expect(values.map(\.0) == ["blob", "blob", "null"])
        #expect(values[0].1 == binary && values[1].1.isEmpty)
    }
}
