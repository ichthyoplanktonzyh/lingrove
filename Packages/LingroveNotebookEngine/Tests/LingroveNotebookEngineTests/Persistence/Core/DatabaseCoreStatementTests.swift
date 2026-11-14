import Foundation
import SQLite3
import Testing
@testable import LingroveNotebookEngine

struct DatabaseCoreStatementTests {
    private func fixture() throws -> (DatabaseCore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statement-" + UUID().uuidString)
        let core = try DatabaseCore(databaseURL: root.appendingPathComponent("test.sqlite"), mediaDirectoryURL: root) { core in
            try core.executeScript(sql: "CREATE TABLE values_test(id INTEGER PRIMARY KEY,text TEXT,bytes BLOB);", errorContext: "Create statement fixture")
            return nil
        }
        return (core, root)
    }

    @Test func reusedWriteClearsBindingsAndRepreparesAfterSchemaChanges() throws {
        let (core, root) = try fixture()
        defer { try? core.close(); try? FileManager.default.removeItem(at: root) }
        let sql = "INSERT INTO values_test(id,text,bytes) VALUES(?,?,?)"
        try core.execute(sql: sql, values: [.integer(1), .text("first"), .blob(Data([0,255]))])
        try core.executeScript(sql: "ALTER TABLE values_test ADD COLUMN extra TEXT;", errorContext: "Change prepared schema")
        // A newly prepared statement leaves missing bindings NULL; reuse must do the same.
        try core.execute(sql: sql, values: [.integer(2), .text("second")])
        let values = try core.query(sql: "SELECT text,typeof(bytes) FROM values_test ORDER BY id", values: []) {
            (DatabaseCore.columnText(statement: $0, index: 0), DatabaseCore.columnText(statement: $0, index: 1))
        }
        #expect(values.map(\.0) == ["first", "second"])
        #expect(values.map(\.1) == ["blob", "null"])
        try core.execute(sql: "UPDATE values_test SET text='Café' WHERE id=1", values: [])
        try core.execute(sql: "UPDATE values_test SET text='Cafe\u{301}' WHERE id=1", values: [])
        let literal = try core.scalarText(sql: "SELECT text FROM values_test WHERE id=1", values: [])
        #expect(literal.utf8.elementsEqual("Cafe\u{301}".utf8))
    }

    @Test func failedStatementAndRolledBackTransactionCanRetry() throws {
        let (core, root) = try fixture()
        defer { try? core.close(); try? FileManager.default.removeItem(at: root) }
        let sql = "INSERT INTO values_test(id,text) VALUES(?,?)"
        try core.execute(sql: sql, values: [.integer(1), .text("original")])
        #expect(throws: (any Error).self) {
            try core.inTransaction {
                try core.execute(sql: sql, values: [.integer(2), .text("rolled back")])
                try core.execute(sql: sql, values: [.integer(1), .text("duplicate")])
            }
        }
        #expect(try core.scalarInt(sql: "SELECT count(*) FROM values_test", values: []) == 1)
        #expect(throws: (any Error).self) {
            try core.execute(sql: sql, values: [.integer(2), .text("bad bind"), .integer(3)])
        }
        try core.execute(sql: sql, values: [.integer(2), .text("retry")])
        #expect(try core.scalarText(sql: "SELECT text FROM values_test WHERE id=2", values: []) == "retry")
    }

    @Test func idleStatementCountIsBoundedAndCloseRejectsNewAccess() throws {
        let (core, root) = try fixture()
        defer { try? core.close(); try? FileManager.default.removeItem(at: root) }
        for number in 0..<100 {
            try core.execute(sql: "UPDATE values_test SET text=? WHERE id=1 /* \(number) */", values: [.text("value")])
        }
        let count = try core.withConnectionAccess {
            var statement: OpaquePointer?, count = 0
            while let next = sqlite3_next_stmt(core.connection, statement) { count += 1; statement = next }
            return count
        }
        #expect(count <= 64 && count > 0)
        try core.close(); try core.close()
        #expect(throws: (any Error).self) { try core.execute(sql: "UPDATE values_test SET text=NULL", values: []) }
    }
}
