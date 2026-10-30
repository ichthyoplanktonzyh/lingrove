import Foundation
import Testing
import LingroveNotebook
@testable import LingroveNotebookStorage

/// The file lock also covers adjacent media work. Its nested-access rules must reject an unsafe
/// shared-to-exclusive upgrade without deadlocking, while allowing work already under a writer.
struct VocabularySQLiteFileLockTests {
    @Test func sharedLockCannotUpgradeAndWriteLockCanBeReentered() throws {
        let directory = try VocabularyStorageTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try VocabularySQLiteFileLock(database: directory.appendingPathComponent("notebook.sqlite"))

        var upgradeBodyRan = false
        #expect(throws: VocabularyError.invalidContent) {
            try lock.access(write: false) {
                try lock.access(write: true) { upgradeBodyRan = true }
            }
        }
        #expect(!upgradeBodyRan)

        var nestedWriterBodyRan = false
        try lock.access(write: true) {
            try lock.access(write: true) {
                try lock.access(write: false) { nestedWriterBodyRan = true }
            }
        }
        #expect(nestedWriterBodyRan)
    }
}
