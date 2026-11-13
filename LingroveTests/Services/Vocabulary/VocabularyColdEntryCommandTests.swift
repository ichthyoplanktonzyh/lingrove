import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import Testing
@testable import Lingrove

/// Production store/archive commands use fresh connections to a private seeded book. A local
/// receipt must refresh pages/favorites without claiming the complete interface is loaded.
@MainActor
struct VocabularyColdEntryCommandTests {
    @Test func coldContextCaptureAndDeletionStayPartialAndCanLaterLoadTheWholeCorpus() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-local-command-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("primary.sqlite"), media = folder.appendingPathComponent("Media")
        let seed = VocabularyArchive(url: database, mediaDirectoryURL: media)
        _ = try await seed.save(capture("existing")); await seed.shutdown()
        let repository = try MacNotebookRepository(databaseURL: database, mediaDirectoryURL: media)
        let store = VocabularyStore(repository: repository), browse = try #require(store.browsing)
        store.browse(.init()); await browse.waitForPage()
        let input = capture("new-context", contextual: true)
        await store.save(input, scope: store.operationScope)
        let saved = try #require(store.lastEntryCommit)
        #expect(!store.isLoaded && store.entries.isEmpty && store.completeSnapshot == nil)
        #expect(await store.savedStatus(input) == true)
        #expect(store.currentRevision == saved.version.revision)
        let destination = try #require(store.explanationDestination(input))
        #expect(destination.entryID == saved.entryID)
        await browse.waitForPage()
        #expect(browse.total == 2)
        let sense = try #require(saved.entry?.senses.first)
        browse.select(senseID: sense.id); await browse.waitForDetail()
        #expect(browse.detail?.examples.count == 1)
        #expect(await store.removeSense(entryID: saved.entryID, senseID: sense.id, scope: store.operationScope))
        #expect(!store.isLoaded && store.entries.isEmpty && store.lastEntryCommit?.entry == nil)
        await browse.waitForPage()
        #expect(browse.total == 1 && browse.detail == nil)
        await store.load()
        #expect(store.isLoaded && store.entries.count == 1 && store.entries[0].expression == "existing")
        #expect(try repository.snapshot().document.sources.contains { $0.text == input.example?.text })
        await store.shutdown(); try repository.shutdown()
    }

    @Test func missingProofUsesCompletePreparationAndLaterColdCommandsUseTheRebuiltProof() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-local-fallback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("primary.sqlite"), media = folder.appendingPathComponent("Media")
        let seed = VocabularyArchive(url: database, mediaDirectoryURL: media)
        _ = try await seed.save(capture("seed")); await seed.shutdown()
        let repository = try MacNotebookRepository(databaseURL: database, mediaDirectoryURL: media)
        let first = VocabularyStore(repository: repository)
        try repository.engine.core.execute(sql: "DELETE FROM notebook_entry_checkpoint", values: [])
        await first.save(capture("full-fallback"), scope: first.operationScope)
        #expect(first.isLoaded && first.entries.count == 2 && first.lastEntryCommit == nil)
        await first.shutdown()
        let second = VocabularyStore(repository: repository), input = capture("local-again")
        await second.save(input, scope: second.operationScope)
        #expect(!second.isLoaded && second.lastEntryCommit != nil && second.entries.isEmpty)
        #expect(await second.savedStatus(input) == true)
        await second.shutdown(); try repository.shutdown()
    }

    private func capture(_ name: String, contextual: Bool = false) -> VocabularyCapture {
        .init(expression: name, dictionaryForm: name, language: .english, kind: .word, meaning: "A saved meaning",
            example: contextual ? .init(id: UUID(), text: "A synthetic example for \(name).", translation: "译文", ranges: [],
                completeness: .sentence, meaning: "Context meaning", createdAt: Date()) : nil)
    }
}
