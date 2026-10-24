import Foundation
import Testing
@testable import Lingrove

/// Tests cross real SQLite transactions and reopen private temporary notebooks. SQL fault
/// injection proves rollback; row-change counts distinguish incremental writes from whole blobs.
@Suite(.serialized)
@MainActor
struct VocabularySQLiteTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }

    @Test func relationalRoundTripRetainsImagesExplanationCardsBindingsAndTemplates() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite")
        var (entries, image) = try VocabularyExportTests().fixture()
        entries[0].senses[0].examples[0].ranges = [.init(NSRange(location: 4, length: 4))]
        let senseID = entries[0].senses[0].id
        let capture = VocabularyCapture(expression: entries[0].expression, dictionaryForm: entries[0].dictionaryForm,
            language: .english, kind: .word, example: entries[0].senses[0].examples[0])
        entries[0].senses[0].examples[0].explanations = [.init(id: UUID(), input: LearningExplanationPolicy.input(capture),
            language: .chinese, result: .init(meaning: "金融机构", explanation: "保留语境解释"), model: "fixture", createdAt: Date())]
        let binding = AnkiNoteBinding(originSenseID: senseID, endpoint: "http://127.0.0.1:8765", profile: "Fixture",
            noteID: 42, model: AnkiReviewPolicy.presetName, deck: "Default", identityField: "LingroveID",
            mapping: AnkiReviewPolicy.presetMapping, fields: ["LingroveID": senseID.uuidString.lowercased()])
        let review = VocabularyReview(plan: .init(layout: ReviewLayoutPolicy.preset(0)), bindings: [binding], activeBindingID: binding.id)
        entries[0].senses[0].review = review; entries[0].senses[0].reviewCards = [review]
        entries[0].senses[1].reviewCards = []
        let template = ReviewLayoutTemplate(name: "Fixture", layout: ReviewLayoutPolicy.preset(0))
        let document = VocabularyDocument(entries: entries, reviewTemplates: [template])
        let archive = VocabularyArchive(url: url)
        let snapshot = try await archive.commitWithImages(document, supplied: [image.reference.filename: image.data])
        #expect(snapshot.document == document)
        let reopened = VocabularyArchive(url: url)
        #expect(try await reopened.load().document == document)
        #expect(try await reopened.load().revision == snapshot.revision)
        #expect(try await reopened.image(image.reference) == image.data)
        #expect(try Data(contentsOf: url).starts(with: Data("SQLite format 3\0".utf8)))
        let database = try VocabularySQLiteDatabase(url: url)
        #expect(try database.connection.rows("PRAGMA foreign_key_check").isEmpty)
        for (table, count) in [("entries", 2), ("senses", 3), ("usages", 1), ("reviews", 2),
                               ("bindings", 2), ("blocks", 3), ("templates", 1), ("usage_explanations", 1)] {
            #expect(try database.connection.rows("SELECT count(*) FROM " + table) == [[.integer(Int64(count))]])
        }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func editingOneNoteWritesOneEntityAndTheRevisionOnly() throws {
        let database = try VocabularySQLiteDatabase(url: nil)
        let source = VocabularyDocument(entries: try VocabularyExportTests().fixture().entries)
        let revision = try database.write(source, previous: .init(), expectedRevision: 0)
        let usageBytes = try database.connection.rows("SELECT payload FROM usages")
        var edited = source; edited.entries[0].senses[0].note = "Only this note changes"
        let next = try database.write(edited, previous: source, expectedRevision: revision)
        #expect(database.lastWrittenRows == 2)
        #expect(try database.connection.rows("SELECT payload FROM usages") == usageBytes)
        #expect(try database.read().document == edited)
        _ = try database.write(edited, previous: edited, expectedRevision: next)
        #expect(database.lastWrittenRows == 1)
    }

    @Test func midTransactionFailureRollsBackParentsChildrenKeysAndRevision() throws {
        let database = try VocabularySQLiteDatabase(url: nil)
        let source = VocabularyDocument(entries: try VocabularyExportTests().fixture().entries)
        let revision = try database.write(source, previous: .init(), expectedRevision: 0)
        try database.connection.execute("CREATE TRIGGER reject_usage BEFORE UPDATE ON usages BEGIN SELECT RAISE(ABORT,'fixture'); END")
        var edited = source
        edited.entries[0].expression = "a bank"; edited.entries[0].dictionaryForm = "a bank"
        edited.entries[0].senses[0].note = "Must roll back"
        edited.entries[0].senses[0].examples[0].translation = "Must roll back too"
        #expect(throws: VocabularyError.self) { _ = try database.write(edited, previous: source, expectedRevision: revision) }
        #expect(try database.read().document == source)
        #expect(try database.revision() == revision)
        #expect(try database.connection.rows("SELECT count(*) FROM entries WHERE lookup_key IS NULL") == [[.integer(0)]])
    }

    @Test func staleConnectionCannotOverwriteAnotherCommitAndArchiveRefreshes() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite")
        let first = try VocabularySQLiteDatabase(url: url), second = try VocabularySQLiteDatabase(url: url)
        let source = VocabularyDocument(entries: try VocabularyExportTests().fixture().entries)
        _ = try first.write(source, previous: .init(), expectedRevision: 0)
        #expect(throws: VocabularyError.editConflict) { _ = try second.write(.init(), previous: .init(), expectedRevision: 0) }
        #expect(try second.read().document == source)
        let archive = VocabularyArchive(url: url); _ = try await archive.load()
        var changed = source; changed.entries[0].senses[0].note = "Other writer"
        _ = try first.write(changed, previous: source, expectedRevision: 1)
        #expect(try await archive.load().document == changed)
    }

    @Test func databaseConstraintAndCorruptPayloadFailWithoutResettingData() throws {
        let database = try VocabularySQLiteDatabase(url: nil)
        let source = VocabularyDocument(entries: try VocabularyExportTests().fixture().entries)
        _ = try database.write(source, previous: .init(), expectedRevision: 0)
        #expect(throws: VocabularyError.self) {
            try database.connection.execute("INSERT INTO senses VALUES ('orphan','missing',0,?,'bad')", [.blob(Data())])
        }
        #expect(try database.read().document == source)
        let bytes = Data("broken payload".utf8)
        try database.connection.execute("UPDATE usages SET payload=?", [.blob(bytes)])
        #expect(throws: VocabularyError.self) { _ = try database.read() }
        #expect(try database.connection.rows("SELECT payload FROM usages") == [[.blob(bytes)]])
    }

    @Test func failedSQLCommitRemovesOnlyNewImages() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite"), archive = VocabularyArchive(url: url)
        let (entries, original) = try VocabularyExportTests().fixture()
        let before = try await archive.commitWithImages(.init(entries: entries), supplied: [original.reference.filename: original.data])
        let database = try VocabularySQLiteDatabase(url: url)
        try database.connection.execute("CREATE TRIGGER fail_commit BEFORE UPDATE ON state BEGIN SELECT RAISE(ABORT,'fixture'); END")
        let image = try VocabularyImageStorage.prepare(VocabularyImageTestFixture.png(width: 100, height: 60))
        var edited = entries[0]
        edited.senses[0].content = [.init(content: .image(image.reference, caption: "Must not survive"))]
        await #expect(throws: VocabularyError.self) {
            _ = try await archive.update(edited, basedOn: entries[0], importedImages: [image.reference.filename: image.data])
        }
        #expect(try await archive.load().document == before.document)
        #expect(try await archive.image(original.reference) == original.data)
        await #expect(throws: (any Error).self) { _ = try await archive.image(image.reference) }
        #expect(!FileManager.default.fileExists(atPath: url.path + ".media/" + image.reference.filename))
    }

    @Test func exportsCannotReplaceWALSidecarsOrAHardLinkToTheDatabase() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite")
        // macOS invalidates SQLite's open vnode when a live file gains a link. Construct the
        // alias while closed so this tests our export guard rather than that OS protection.
        do { let database = try VocabularySQLiteDatabase(url: url); database.connection.close() }
        let link = directory.appendingPathComponent("innocent.json")
        try FileManager.default.linkItem(at: url, to: link)
        let archive = VocabularyArchive(url: url)
        _ = try await archive.load()
        for suffix in ["", "-wal", "-shm", "-journal", ".lock"] {
            await #expect(throws: VocabularyError.invalidContent) { try await archive.export(to: URL(fileURLWithPath: url.path + suffix)) }
        }
        await #expect(throws: VocabularyError.invalidContent) { try await archive.export(to: link) }
        #expect(try await archive.load().document.entries.isEmpty)
    }

    @Test func sharedMediaSnapshotPreventsAnotherWriterUntilItFinishes() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite")
        let first = try VocabularySQLiteDatabase(url: url), second = try VocabularySQLiteDatabase(url: url)
        let source = VocabularyDocument(entries: try VocabularyExportTests().fixture().entries)
        try first.access(write: false) { () throws -> Void in
            #expect(throws: VocabularyError.storageBusy) {
                _ = try second.write(source, previous: .init(), expectedRevision: 0)
            }
            let current = try first.read()
            #expect(current.document.entries.isEmpty)
        }
        _ = try second.write(source, previous: .init(), expectedRevision: 0)
        #expect(try first.read().document == source)
    }

    @Test func symlinkDatabaseIsRejectedAndOldJSONIsIgnored() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("notebook-v3.json"), bytes = Data("Old JSON is not imported".utf8)
        try bytes.write(to: old)
        let url = directory.appendingPathComponent("notebook.sqlite")
        #expect(try await VocabularyArchive(url: url).load().document.entries.isEmpty)
        #expect(try Data(contentsOf: old) == bytes)
        let link = directory.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        await #expect(throws: VocabularyError.self) { _ = try await VocabularyArchive(url: link).load() }
        #expect(try Data(contentsOf: old) == bytes)
    }
}
