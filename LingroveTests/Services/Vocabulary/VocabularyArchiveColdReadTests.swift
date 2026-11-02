@testable import LingroveNotebookStorage
import LingroveNotebook
import LingroveStudyExport
import Foundation
import Testing
@testable import Lingrove

/// Cold-read regressions cover archive entry points that perform catalog installation before
/// taking a shared media snapshot. Each test uses a UUID-scoped SQLite file so no user notebook
/// or downloaded learning data can enter the fixture.
@Suite(.serialized)
@MainActor
struct VocabularyArchiveColdReadTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Seed through the storage boundary so the tested archive instance is genuinely new and
    /// has never loaded or cached this committed document.
    private func seed(_ document: VocabularyDocument, at url: URL) throws -> UInt64 {
        let database = try VocabularySQLiteDatabase(url: url)
        return try database.write(document, previous: .init(), expectedRevision: 0)
    }

    @Test func backupFromColdArchivePersistsBundledClassificationBeforeSharedRead() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("notebook.sqlite")
        let backupURL = folder.appendingPathComponent("backup.lingrove")
        var archive: VocabularyArchive? = VocabularyArchive(url: url, installsBundledClassification: true)
        var reopenedArchive: VocabularyArchive? = nil
        defer {
            // Release archive-owned SQLite handles before removing their database and WAL files.
            archive = nil
            reopenedArchive = nil
            try? FileManager.default.removeItem(at: folder)
        }

        try await archive!.backup(to: backupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        let backup = try JSONDecoder().decode(VocabularyBackup.self, from: Data(contentsOf: backupURL))
        #expect(!backup.document.classification.frameworks.isEmpty)
        #expect(!backup.document.classification.categories.isEmpty)

        let afterBackup = try await archive!.load()
        #expect(backup.document == afterBackup.document)
        let repeated = try await archive!.load()
        #expect(repeated.revision == afterBackup.revision)

        // A second actor proves the catalog was committed to SQLite, not only retained in cache.
        reopenedArchive = VocabularyArchive(url: url, installsBundledClassification: true)
        let reopened = try await reopenedArchive!.load()
        #expect(reopened.document == backup.document)
        #expect(reopened.revision == afterBackup.revision)
    }

    @Test func coldSelectedExportInstallsClassificationOnceAndKeepsSelection() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("notebook.sqlite")
        let expected = VocabularySemanticTests.fixture()
        let seededRevision = try seed(expected, at: url)
        let expectedEntry = try #require(expected.entries.first)
        let expectedSense = try #require(expectedEntry.senses.first)
        let selection = VocabularySelection(entryID: expectedEntry.id, senseID: expectedSense.id)
        var archive: VocabularyArchive? = VocabularyArchive(url: url, installsBundledClassification: true)
        defer {
            archive = nil
            try? FileManager.default.removeItem(at: folder)
        }

        var configuration = VocabularyExportConfiguration()
        configuration.format = .json
        let package = try await archive!.prepareExport(selections: [selection], configuration: configuration)
        #expect(package.entryCount == 1)
        #expect(package.senseCount == 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(VocabularyExportDocument.self, from: package.data)
        let exportedEntry = try #require(exported.entries.first)
        let exportedSense = try #require(exportedEntry.senses.first)
        #expect(exported.entries.count == 1)
        #expect(exportedEntry.id == expectedEntry.id)
        #expect(exportedEntry.expression == expectedEntry.expression)
        #expect(exportedEntry.senses.count == 1)
        #expect(exportedSense.id == expectedSense.id)
        #expect(exportedSense.meaning == expectedSense.meaning)

        let installed = try await archive!.load()
        #expect(installed.revision == seededRevision + 1)
        #expect(!installed.document.classification.frameworks.isEmpty)
        let repeatedPackage = try await archive!.prepareExport(selections: [selection], configuration: configuration)
        #expect(repeatedPackage.senseCount == 1)
        let stable = try await archive!.load()
        #expect(stable.revision == installed.revision)
        #expect(stable.document.classification == installed.document.classification)
    }
}
