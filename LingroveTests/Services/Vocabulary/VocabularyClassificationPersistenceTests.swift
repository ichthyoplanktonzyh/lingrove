import Foundation
import Testing
@testable import Lingrove

@Suite(.serialized)
@MainActor
struct VocabularyClassificationPersistenceTests {
    @Test func appCatalogInstallationIsIdempotentAndNeverGuessesMemberships() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: url, installsBundledClassification: true)
        let first = try await archive.load(), again = try await archive.load()
        #expect(first.document.classification.categories.count == 256)
        #expect(first.document.classification.memberships.isEmpty && first.document.catalog.isEmpty)
        #expect(first.revision == 1 && again.revision == first.revision && again.document == first.document)
        let reopened = try await VocabularyArchive(url: url, installsBundledClassification: true).load()
        #expect(reopened.revision == first.revision && reopened.document == first.document)
    }

    @Test func fullBackupRetainsClassificationAndOldBackupRestoresWithoutInventingLinks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backup = folder.appendingPathComponent("backup.json"), source = VocabularyArchive(url: nil)
        var document = VocabularySemanticTests.fixture()
        try VocabularyClassificationTests.catalog().install(in: &document.classification, nodes: document.semantics.nodes)
        let category = document.classification.categories[1]
        document.classification.memberships = [.init(id: UUID(), nodeID: document.semantics.nodes[0].id, categoryID: category.id)]
        document.classification.overrides = [.init(categoryID: category.id, definition: "Local definition", isHidden: true)]
        _ = try await source.commit(document); try await source.backup(to: backup)
        let restored = try await VocabularyArchive(url: nil).restore(from: backup)
        #expect(restored.document == document)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any])
        var old = try #require(envelope["document"] as? [String: Any])
        old["schemaVersion"] = 7; old.removeValue(forKey: "classification"); envelope["document"] = old
        try JSONSerialization.data(withJSONObject: envelope).write(to: backup)
        let upgraded = try await VocabularyArchive(url: nil).restore(from: backup)
        #expect(upgraded.document.entries == document.entries && upgraded.document.semantics == document.semantics)
        #expect(upgraded.document.classification == .init())
    }

    @Test func SQLiteUpgradePreservesEvidenceReceiptsAndRevision() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite"), document = VocabularySemanticTests.fixture()
        let receipt = VocabularyCLIReceipt(key: "existing", fingerprint: "fixture", result: Data("receipt".utf8))
        let original = try VocabularySQLiteDatabase(url: url)
        _ = try original.write(document, previous: .init(), expectedRevision: 0, receipt: receipt)
        let evidence = try original.connection.rows("SELECT id,payload FROM usages ORDER BY id")
        for table in VocabularySQLiteClassificationSchema.tables.reversed() {
            try original.connection.execute("DROP TABLE " + table.rawValue)
        }
        try original.connection.execute("PRAGMA user_version=4"); original.connection.close()
        let reopened = try VocabularySQLiteDatabase(url: url)
        #expect(try reopened.read().document == document)
        #expect(try reopened.revision() == 1)
        #expect(try reopened.receipt(key: "existing")?.result == receipt.result)
        #expect(try reopened.connection.rows("SELECT id,payload FROM usages ORDER BY id") == evidence)
        #expect(try reopened.connection.rows("PRAGMA user_version") == [[.integer(5)]])
    }

    @Test func failedSchemaUpgradeRollsBackAllNewTables() throws {
        let connection = try VocabularySQLiteConnection(url: nil)
        try connection.execute("CREATE TABLE categories (fixture TEXT)")
        try connection.execute("PRAGMA user_version=4")
        #expect(throws: VocabularyError.self) { try VocabularySQLiteClassificationSchema.migrate(connection) }
        #expect(try connection.rows("PRAGMA user_version") == [[.integer(4)]])
        #expect(try connection.rows("SELECT name FROM sqlite_master WHERE name='classification_frameworks'").isEmpty)
        #expect(try connection.rows("SELECT name FROM sqlite_master WHERE name='categories'") == [[.text("categories")]])
    }

    @Test func classificationRoundTripsAndOneOverlayDoesNotRewriteMeaningRows() throws {
        let database = try VocabularySQLiteDatabase(url: nil)
        var document = VocabularySemanticTests.fixture()
        try VocabularyClassificationTests.catalog().install(in: &document.classification, nodes: document.semantics.nodes)
        let category = document.classification.categories[1]
        document.classification.memberships = [.init(id: UUID(), nodeID: document.semantics.nodes[0].id, categoryID: category.id)]
        let revision = try database.write(document, previous: .init(), expectedRevision: 0)
        #expect(try database.read().document == document)
        let meanings = try database.connection.rows("SELECT id,payload FROM meaning_nodes ORDER BY id")
        var edited = document; edited.classification.overrides.append(.init(categoryID: category.id, isHidden: true))
        _ = try database.write(edited, previous: document, expectedRevision: revision)
        #expect(database.lastWrittenRows == 2)
        #expect(try database.connection.rows("SELECT id,payload FROM meaning_nodes ORDER BY id") == meanings)
        #expect(try database.read().document == edited)
    }

    @Test func removingMeaningThroughEditorCleansOnlyItsMemberships() async throws {
        let archive = VocabularyArchive(url: nil)
        var document = VocabularySemanticTests.fixture()
        let category = VocabularyClassificationTests.category("Meaning category")
        document.classification.categories = [category]
        document.classification.memberships = [.init(id: UUID(), nodeID: document.semantics.nodes[0].id, categoryID: category.id)]
        _ = try await archive.commit(document)
        var edited = document.semantics
        VocabularySemanticPolicy.removeNode(document.semantics.nodes[0].id, from: &edited)
        let snapshot = try await archive.updateSemantics(edited, basedOn: document.semantics)
        #expect(snapshot.document.classification.memberships.isEmpty)
        #expect(snapshot.document.classification.categories == [category])
        #expect(snapshot.document.entries == document.entries)
    }
}
