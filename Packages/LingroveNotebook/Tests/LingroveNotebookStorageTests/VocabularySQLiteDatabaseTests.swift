import Foundation
import Testing
import LingroveNotebook
@testable import LingroveNotebookStorage

/// These tests pin storage behavior at the module boundary: stable relational identities, receipt
/// durability, compare-and-swap, and protection against replacing the path behind an open handle.
struct VocabularySQLiteDatabaseTests {
    @Test func schema5FixtureReopensWithoutChangingItsRevisionOrOrderedIdentities() throws {
        let directory = try VocabularyStorageTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try VocabularyStorageTestSupport.copiedSchema5Fixture(to: directory)
        let database = try VocabularySQLiteDatabase(url: url)
        defer { database.connection.close() }

        #expect(VocabularySQLiteDatabase.schemaVersion == 5)
        let schemaVersionBeforeRead = try database.access(write: false) {
            try database.connection.rows("PRAGMA user_version").first?.first?.integer
        }
        let applicationID = try database.access(write: false) {
            try database.connection.rows("PRAGMA application_id").first?.first?.integer
        }
        #expect(schemaVersionBeforeRead == 5)
        #expect(applicationID == 0x4C47564E)
        #expect(try database.revision() == 1)
        let beforeReadRevision = try database.revision()
        let snapshot = try database.read()
        let receipt = try #require(try database.receipt(key: "fixture-seed"))
        let schemaVersionAfterRead = try database.access(write: false) {
            try database.connection.rows("PRAGMA user_version").first?.first?.integer
        }

        #expect(snapshot.revision == beforeReadRevision)
        #expect(try database.revision() == beforeReadRevision)
        #expect(schemaVersionAfterRead == schemaVersionBeforeRead)
        #expect(snapshot.document.catalog.map(\.id.uuidString) == ["10000000-0000-0000-0000-000000000001"])
        #expect(snapshot.document.catalog[0].senses.map(\.id.uuidString) == [
            "20000000-0000-0000-0000-000000000001",
            "20000000-0000-0000-0000-000000000002"
        ])
        #expect(snapshot.document.sources.map(\.id.uuidString) == [
            "30000000-0000-0000-0000-000000000001",
            "30000000-0000-0000-0000-000000000002"
        ])
        #expect(snapshot.document.occurrences.map(\.id.uuidString) == [
            "40000000-0000-0000-0000-000000000001",
            "40000000-0000-0000-0000-000000000002"
        ])
        #expect(snapshot.document.interpretations.map(\.id.uuidString) == [
            "50000000-0000-0000-0000-000000000001",
            "50000000-0000-0000-0000-000000000002"
        ])
        #expect(snapshot.document.catalog[0].senses[1].reviewCards?.first?.plan.name == "Meaning recall")
        #expect(snapshot.document.semantics.nodes.map(\.id.uuidString) == [
            "60000000-0000-0000-0000-000000000001",
            "60000000-0000-0000-0000-000000000002"
        ])
        #expect(snapshot.document.classification.memberships.first?.nodeID.uuidString ==
            "60000000-0000-0000-0000-000000000001")
        #expect(receipt.key == "fixture-seed")
        #expect(receipt.fingerprint == "synthetic-v1")
        #expect(receipt.result == Data("{\"fixture\":\"schema5\",\"case\":\"ambiguous-bank\"}".utf8))
    }

    @Test func compareAndSwapRejectsStaleRevisionAndReceiptFailureRollsBackRows() throws {
        let database = try VocabularySQLiteDatabase(url: nil)
        defer { database.connection.close() }

        let empty = VocabularyDocument()
        let original = VocabularyStorageTestSupport.lexicalDocument("bank")
        let edited = VocabularyStorageTestSupport.lexicalDocument("banking")
        let receipt = VocabularyCLIReceipt(key: "batch-1", fingerprint: "fingerprint-1", result: Data([1, 2, 3]))

        #expect(try database.write(original, previous: empty, expectedRevision: 0, receipt: receipt) == 1)
        #expect(throws: VocabularyError.editConflict) {
            try database.write(edited, previous: original, expectedRevision: 0)
        }
        #expect(try database.read().document == original)
        #expect(try database.revision() == 1)

        // The duplicate receipt fails after changed rows have been upserted. They must be part of
        // the same transaction, so the new expression and revision are both rolled back.
        #expect(throws: VocabularyError.self) {
            try database.write(edited, previous: original, expectedRevision: 1, receipt: receipt)
        }
        #expect(try database.read().document == original)
        #expect(try database.revision() == 1)
        let storedReceipt = try #require(try database.receipt(key: receipt.key))
        #expect(storedReceipt.fingerprint == receipt.fingerprint)
        #expect(storedReceipt.result == receipt.result)
    }

    @Test func databaseRejectsSymlinkAndReplacementOfItsNamedFile() throws {
        let directory = try VocabularyStorageTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite")
        let database = try VocabularySQLiteDatabase(url: url)
        defer { database.connection.close() }

        let detached = directory.appendingPathComponent("detached.sqlite")
        try FileManager.default.moveItem(at: url, to: detached)
        try Data("replacement".utf8).write(to: url)
        #expect(throws: VocabularyError.invalidArchive) { _ = try database.read() }

        let symlink = directory.appendingPathComponent("notebook-link.sqlite")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: detached)
        #expect(throws: VocabularyError.invalidArchive) { _ = try VocabularySQLiteDatabase(url: symlink) }
    }
}
