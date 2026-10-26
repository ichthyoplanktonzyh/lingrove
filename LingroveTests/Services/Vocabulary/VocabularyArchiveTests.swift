import Foundation
import Testing
@testable import Lingrove

nonisolated struct VocabularyArchiveTests {
    @Test func unknownContextSurvivesStorageAndUsesAVersionedExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        var input = capture()
        input.example?.completeness = .unknown
        let saved = try await VocabularyArchive(url: url).save(input)
        #expect(saved.document.schemaVersion == 5)
        let reopened = try await VocabularyArchive(url: url).load()
        #expect(reopened.document == saved.document)
        #expect(reopened.document.entries.first?.examples.first?.completeness == .unknown)
        let decoded = try JSONDecoder().decode(VocabularyDocument.self, from: JSONEncoder().encode(reopened.document))
        #expect(decoded == reopened.document)
        let exported = VocabularyExportPolicy.document(decoded.entries, configuration: .init(format: .json))
        #expect(exported.version == 3)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(exported)) as? [String: Any])
        #expect(object["version"] as? Int == 3)
    }

    @Test func newUncertainEvidenceReusesOneSavedUsageWithoutChangingItsExplicitClassification() async throws {
        let archive = VocabularyArchive(url: nil)
        var input = capture()
        input.example?.completeness = .fragment
        let first = try await archive.save(input)
        input.example?.completeness = .unknown
        let repeated = try await archive.save(input)
        #expect(repeated.document.entries[0].senses.count == 1 && repeated.document.entries[0].examples.count == 1)
        #expect(first.document.entries[0].examples[0].id == repeated.document.entries[0].examples[0].id)
        #expect(repeated.document.entries[0].examples[0].completeness == .fragment)
        #expect(repeated.document.schemaVersion == 3)

        let other = VocabularyArchive(url: nil)
        let uncertain = try await other.save(input)
        input.example?.completeness = .sentence
        let confirmed = try await other.save(input)
        #expect(confirmed.document.entries[0].examples.count == 1)
        #expect(confirmed.document.entries[0].examples[0].id == uncertain.document.entries[0].examples[0].id)
        #expect(confirmed.document.entries[0].examples[0].completeness == .sentence && confirmed.document.schemaVersion == 3)
    }

    @Test func uncertainEvidenceDoesNotMergeAmbiguousLegacyUsages() throws {
        var document = VocabularyDocument(), input = capture()
        input.example?.completeness = .fragment
        _ = try VocabularyPolicy.save(input, in: &document, now: Date())
        input.example?.completeness = .sentence
        _ = try VocabularyPolicy.save(input, in: &document, now: Date())
        input.example?.completeness = .unknown
        #expect(throws: VocabularyError.editConflict) { try VocabularyPolicy.save(input, in: &document, now: Date()) }
        #expect(document.entries[0].senses.count == 2 && document.entries[0].examples.count == 2)
    }

    @Test func exportsOnlyLearningContentInSchemaThree() async throws {
        let archive = VocabularyArchive(url: nil)
        let snapshot = try await archive.save(capture())
        let encoded = try JSONEncoder().encode(snapshot.document)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        #expect(snapshot.document.schemaVersion == 3)
        #expect(entries[0]["definitions"] == nil)
        #expect(entries[0]["senses"] != nil)
    }

    @Test func repeatedWordComponentsKeepDistinctUsageIDsAcrossReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let words = [LearningDictionaryWord(text: "as", range: NSRange(location: 5, length: 2)),
                     LearningDictionaryWord(text: "as", range: NSRange(location: 13, length: 2))]
        let unit = LearningUnit(id: 5, surface: "as soon as", query: "as soon as", kind: .expression,
            ranges: [NSRange(location: 5, length: 10)], words: words)
        let phrase = VocabularyCapture(expression: unit.surface, dictionaryForm: unit.query, language: .english, kind: .expression,
            example: VocabularyPolicy.example(text: "Come as soon as you can.", ranges: unit.ranges, language: .english))
        let first = try #require(VocabularyCaptureFactory.component(words[0], unit: unit, capture: phrase))
        let second = try #require(VocabularyCaptureFactory.component(words[1], unit: unit, capture: phrase))
        #expect(first.example?.id == second.example?.id, "Both controls originate from the same phrase receipt")
        let archive = VocabularyArchive(url: url)
        _ = try await archive.save(first)
        _ = try await archive.save(second)
        _ = try await archive.save(second)
        let reopened = try await VocabularyArchive(url: url).load()
        let entry = try #require(reopened.document.entries.first)
        #expect(reopened.document.entries.count == 1 && entry.examples.count == 2)
        #expect(Set(entry.examples.map(\.id)).count == 2)
        #expect(entry.examples[0].ranges != entry.examples[1].ranges)
        let fresh = VocabularyArchive(url: url)
        let removed = try await fresh.remove(first)
        #expect(removed.document.entries[0].examples.count == 1)
        #expect(VocabularyPolicy.contains(second, in: removed.document.entries))
    }

    @Test @MainActor func notebookWorkflowPersistsEditsExportAndSelectiveRemoval() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let store = VocabularyStore(archive: VocabularyArchive(url: url))
        let first = capture()
        var second = first
        second.example = VocabularyPolicy.example(text: "They posted the letter.",
            ranges: [NSRange(location: 5, length: 6)], language: .english)
        await store.save(first)
        await store.save(first)
        await store.save(second)
        #expect(store.entries.count == 1 && store.entries[0].examples.count == 2)
        let baseline = try #require(store.entries.first)
        var edited = baseline
        edited.senses[0].note = "Release acceptance note"
        edited.senses[0].tags = ["Work"]
        #expect(await store.update(edited, basedOn: baseline))
        var opened: UUID?
        store.openSelection = { opened = $0?.entryID }
        store.show(first)
        #expect(opened == baseline.id)
        let exported = folder.appendingPathComponent("export.json")
        await store.export(to: exported)
        let document = try JSONDecoder().decode(VocabularyDocument.self, from: Data(contentsOf: exported))
        #expect(document.entries == store.entries)
        let reopened = try await VocabularyArchive(url: url).load()
        #expect(reopened.document == document)
        await store.remove(first)
        #expect(!store.contains(first) && store.contains(second))
        #expect(store.entries[0].senses[0].note == edited.senses[0].note && store.entries[0].senses[0].tags == edited.senses[0].tags)
        #expect(await store.remove(id: baseline.id))
        #expect(try await VocabularyArchive(url: url).load().document.entries.isEmpty)
    }

    @Test func savedItemSurvivesReopenWithStableIDsAndEditableContent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: url)
        let snapshot = try await archive.save(capture())
        let baseline = try #require(snapshot.document.entries.first)
        var entry = baseline
        entry.senses[0].note = "My note"; entry.senses[0].tags = ["Work"]; entry.senses[0].meaning = "Keep me informed"
        _ = try await archive.update(entry, basedOn: baseline)
        let reopened = try await VocabularyArchive(url: url).load()
        #expect(reopened.document.entries.first?.id == entry.id)
        #expect(reopened.document.entries.first?.senses.first?.note == "My note")
        #expect(reopened.document.entries.first?.senses.first?.tags == ["Work"])
    }

    @Test func concurrentSavesSerializeWithoutLostEntries() async throws {
        let archive = VocabularyArchive(url: nil)
        async let first = archive.save(capture("posted"))
        async let second = archive.save(capture("progress"))
        _ = try await (first, second)
        let snapshot = try await archive.load()
        #expect(Set(snapshot.document.entries.map(\.expression)) == ["posted", "progress"])
    }

    @Test func removingOneUsagePreservesOtherContextAndNotes() async throws {
        let archive = VocabularyArchive(url: nil)
        let first = capture()
        var second = first
        second.example = VocabularyPolicy.example(text: "They posted the letter.",
            ranges: [NSRange(location: 5, length: 6)], language: .english)
        _ = try await archive.save(first)
        _ = try await archive.save(second)
        let snapshot = try await archive.remove(first)
        #expect(snapshot.document.entries.count == 1)
        #expect(snapshot.document.entries[0].examples.count == 1)
        #expect(snapshot.document.entries[0].examples[0].text == second.example?.text)
    }

    @Test func corruptArchiveIsPreservedAndCannotBeOverwrittenBySave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let bytes = Data("broken data".utf8)
        try bytes.write(to: url)
        let archive = VocabularyArchive(url: url)
        await #expect(throws: (any Error).self) { try await archive.save(capture()) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func unknownSchemaVersionIsNotReset() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let database = try VocabularySQLiteDatabase(url: url)
        try database.connection.execute("PRAGMA user_version=999")
        await #expect(throws: VocabularyError.unsupportedVersion) { try await VocabularyArchive(url: url).load() }
        #expect(try database.connection.rows("PRAGMA user_version") == [[.integer(999)]])
    }

    @Test func exportRoundTripsAllExamplesAndDoesNotOverwriteLiveArchive() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: url)
        let snapshot = try await archive.save(capture())
        let exported = folder.appendingPathComponent("export.json")
        try await archive.export(to: exported)
        let decoded = try JSONDecoder().decode(VocabularyDocument.self, from: Data(contentsOf: exported))
        #expect(decoded == snapshot.document)
        await #expect(throws: (any Error).self) { try await archive.export(to: url) }
    }

    @Test @MainActor func failedWriteDoesNotTurnFavoriteBlue() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = VocabularyStore(archive: VocabularyArchive(url: folder.appendingPathComponent("notebook.sqlite")))
        let value = capture()
        await store.save(value)
        #expect(!store.contains(value))
        #expect(store.errorMessage != nil)
        #expect(!store.isPending(value))
    }

    @Test func staleEditorPreservesContextsSavedAfterItOpened() async throws {
        let archive = VocabularyArchive(url: nil)
        let first = try await archive.save(capture())
        let baseline = try #require(first.document.entries.first)
        var next = capture()
        next.example?.text = "They posted the letter."
        next.example?.ranges = [VocabularyTextRange(NSRange(location: 5, length: 6))]
        _ = try await archive.save(next)
        var edited = baseline
        edited.senses[0].note = "Written while another example was saved"
        let merged = try await archive.update(edited, basedOn: baseline)
        #expect(merged.document.entries[0].examples.count == 2)
        #expect(merged.document.entries[0].senses[0].note == edited.senses[0].note)
    }

    @Test func conflictingEditsDoNotOverwriteEachOther() async throws {
        let archive = VocabularyArchive(url: nil)
        let snapshot = try await archive.save(capture())
        let baseline = try #require(snapshot.document.entries.first)
        var one = baseline, two = baseline
        one.senses[0].note = "First edit"; two.senses[0].note = "Second edit"
        _ = try await archive.update(one, basedOn: baseline)
        await #expect(throws: (any Error).self) { try await archive.update(two, basedOn: baseline) }
        #expect(try await archive.load().document.entries[0].senses[0].note == "First edit")
    }

    @Test func removingStandaloneFavoriteDoesNotEraseSavedExamples() async throws {
        let archive = VocabularyArchive(url: nil)
        let withContext = capture()
        var standalone = withContext
        standalone.example = nil
        _ = try await archive.save(withContext)
        _ = try await archive.save(standalone)
        let removed = try await archive.remove(standalone)
        #expect(removed.document.entries.count == 1)
        #expect(removed.document.entries[0].examples.count == 1)
        #expect(!removed.document.entries[0].senses.contains { $0.isSavedWithoutContext })
    }

    @Test func invalidArchiveRangesFailWithoutChangingTheFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let snapshot = try await VocabularyArchive(url: url).save(capture())
        var invalid = snapshot.document.entries[0].examples[0]
        invalid.ranges = [VocabularyTextRange(NSRange(location: 9_999, length: 5))]
        let bytes = try VocabularyDatabaseRecord.Payload.usage(invalid).encoded()
        let connection = try VocabularySQLiteConnection(url: url)
        try connection.execute("UPDATE usages SET payload=? WHERE id=?", [.blob(bytes), .text(invalid.id.uuidString)])
        await #expect(throws: (any Error).self) { try await VocabularyArchive(url: url).save(capture()) }
        #expect(try connection.rows("SELECT payload FROM usages WHERE id=?", [.text(invalid.id.uuidString)]) == [[.blob(bytes)]])
    }

    @Test func oldSchemaIsRejectedWithoutRewritingIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("notebook.sqlite")
        let database = try VocabularySQLiteDatabase(url: url)
        try database.connection.execute("PRAGMA user_version=0")
        await #expect(throws: VocabularyError.unsupportedVersion) { try await VocabularyArchive(url: url).load() }
        #expect(try database.connection.rows("PRAGMA user_version") == [[.integer(0)]])
    }

    @Test func contextlessTranslationsInDifferentLanguagesAreBothRetained() async throws {
        let archive = VocabularyArchive(url: nil)
        var chinese = capture(), spanish = capture()
        chinese.example = nil; chinese.meaning = "告知"; chinese.meaningLanguage = .chinese
        spanish.example = nil; spanish.meaning = "informar"; spanish.meaningLanguage = .spanish
        _ = try await archive.save(chinese)
        let result = try await archive.save(spanish)
        #expect(result.document.entries.count == 1)
        #expect(result.document.entries[0].senses[0].standaloneMeanings.map(\.text) == ["告知", "informar"])
        #expect(VocabularyPolicy.contains(chinese, in: result.document.entries))
        #expect(VocabularyPolicy.contains(spanish, in: result.document.entries))
        let removed = try await archive.remove(chinese)
        #expect(!VocabularyPolicy.contains(chinese, in: removed.document.entries))
        #expect(!VocabularyPolicy.contains(spanish, in: removed.document.entries))
    }

    @Test func manuallyAddedExampleSurvivesSaveAndCanBeRemovedWithoutDeletingTheWord() async throws {
        let archive = VocabularyArchive(url: nil)
        var standalone = capture()
        standalone.example = nil
        let first = try await archive.save(standalone)
        let baseline = try #require(first.document.entries.first)
        var edited = baseline
        edited.senses[0].examples = [try #require(capture().example)]
        let added = try await archive.update(edited, basedOn: baseline)
        #expect(added.document.entries[0].examples.count == 1)
        let withExample = added.document.entries[0]
        edited = withExample
        edited.senses[0].examples = []
        let removed = try await archive.update(edited, basedOn: withExample)
        #expect(removed.document.entries.count == 1)
        #expect(removed.document.entries[0].examples.isEmpty)
        #expect(removed.document.entries[0].senses[0].isSavedWithoutContext)
    }

    @Test func deletingLastExampleDoesNotResurrectARemovedGeneralSense() async throws {
        let archive = VocabularyArchive(url: nil)
        _ = try await archive.save(capture())
        var standalone = capture()
        standalone.example = nil
        standalone.meaning = "Inform someone"
        standalone.meaningLanguage = .english
        let snapshot = try await archive.save(standalone)
        let baseline = try #require(snapshot.document.entries.first)
        _ = try await archive.remove(standalone)
        var edited = baseline
        edited.senses[0].examples = []
        _ = try await archive.update(edited, basedOn: baseline)
        let current = try await archive.load().document.entries[0]
        #expect(!current.senses[0].isSavedWithoutContext)
        #expect(current.senses[0].standaloneMeanings.isEmpty)
        #expect(current.examples.isEmpty)
    }

    private func capture(_ expression: String = "posted") -> VocabularyCapture {
        let text = "Please keep me posted on the progress."
        return VocabularyCapture(expression: expression, dictionaryForm: expression, language: .english, kind: .word,
            example: VocabularyPolicy.example(text: text, ranges: [(text as NSString).range(of: expression)], language: .english))
    }
}
