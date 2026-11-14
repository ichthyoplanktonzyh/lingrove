import Foundation
import Testing
import LingroveNotebook
@testable import LingroveNotebookStorage

/// These tests pin storage behavior at the module boundary: stable relational identities, receipt
/// durability, compare-and-swap, and protection against replacing the path behind an open handle.
struct VocabularySQLiteDatabaseTests {

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
