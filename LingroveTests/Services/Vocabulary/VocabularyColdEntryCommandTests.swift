import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import Testing
@testable import Lingrove

/// Production store/archive commands use fresh connections to a private seeded book. A local
/// receipt must refresh pages/favorites without claiming the complete interface is loaded.
@MainActor
struct VocabularyColdEntryCommandTests {
    @Test func coldReviewedEditorKeepsPagesPartial() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-local-editor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("primary.sqlite"), media = folder.appendingPathComponent("Media")
        let seed = VocabularyArchive(url: database, mediaDirectoryURL: media)
        _ = try await seed.save(capture("reviewed edit", contextual: true)); await seed.shutdown()
        let repository = try MacNotebookRepository(databaseURL: database, mediaDirectoryURL: media)
        let saved = try repository.snapshot(), original = try #require(saved.document.entries.first)
        let sense = try #require(original.senses.first)
        _ = try repository.engine.enrollReviewNotes(selections: [.init(entryID: original.id, senseID: sense.id)], version: .init(saved))
        let store = VocabularyStore(repository: repository), browse = try #require(store.browsing)
        do {
            store.browse(.init()); await browse.waitForPage()
            browse.select(senseID: sense.id); await browse.waitForDetail()
            var edited = original; edited.senses[0].note = "Updated through the paged editor"
            #expect(await store.update(edited, basedOn: original, scope: store.operationScope))
            #expect(!store.isLoaded && store.entries.isEmpty && store.lastEntryCommit?.entry?.senses[0].note == edited.senses[0].note)
            await browse.waitForPage(); await browse.waitForDetail()
            #expect(browse.total == 1 && store.completeSnapshot == nil)
            await store.load()
            #expect(store.entries[0].senses.count == 1 && store.entries[0].senses.contains { $0.note == edited.senses[0].note })
            #expect(try repository.engine.loadLingroveNotebookCardLinks(workspaceId: saved.workspaceId).count == 1)
            await store.shutdown(); try repository.shutdown()
        } catch { await store.shutdown(); try? repository.shutdown(); throw error }
    }

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

    @Test func coldReviewedRetirementRefreshesPagesAndKeepsTheSavedCardAndHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-reviewed-retirement-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("primary.sqlite"), media = folder.appendingPathComponent("Media")
        let seed = VocabularyArchive(url: database, mediaDirectoryURL: media)
        _ = try await seed.save(capture("reviewed", contextual: true))
        _ = try await seed.save(capture("unrelated")); await seed.shutdown()
        let repository = try MacNotebookRepository(databaseURL: database, mediaDirectoryURL: media)
        let saved = try repository.snapshot(), entry = try #require(saved.document.entries.first { $0.expression == "reviewed" })
        let sense = try #require(entry.senses.first)
        _ = try repository.engine.enrollReviewNotes(selections: [.init(entryID: entry.id, senseID: sense.id)], version: .init(saved))
        let review = try repository.engine.loadBuiltInNotebookReview(scope: saved, now: Date())
        let question = try #require(review.queue.first), model = try #require(review.noteCards[question.cardId])
        _ = try repository.engine.submitReview(workspaceId: saved.workspaceId, reviewSubmission: .init(cardId: question.cardId,
            rating: .good, reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC", noteVersion: model.questionVersion(in: saved)))
        let card = try repository.engine.loadActiveCard(workspaceId: saved.workspaceId, cardId: question.cardId)
        let store = VocabularyStore(repository: repository), browse = try #require(store.browsing)
        do {
            store.browse(.init()); await browse.waitForPage()
            browse.select(senseID: sense.id); await browse.waitForDetail()
            #expect(await store.removeSense(entryID: entry.id, senseID: sense.id, scope: store.operationScope))
            #expect(!store.isLoaded && store.entries.isEmpty && store.completeSnapshot == nil)
            #expect(store.lastEntryCommit?.entry == nil && store.errorMessage == nil)
            await browse.waitForPage()
            #expect(browse.total == 1 && browse.detail == nil)
            #expect(await store.savedStatus(capture("reviewed", contextual: true)) == false)
            #expect(try repository.engine.loadActiveCard(workspaceId: saved.workspaceId, cardId: question.cardId) == card)
            #expect(try repository.engine.loadReviewEventCount() == 1)
            #expect(try repository.engine.core.scalarOptionalText(sql: """
                SELECT status FROM notebook_review_material_state WHERE workspace_id=? AND card_id=?
                """, values: [.text(saved.workspaceId), .text(card.cardId)]) == "sourceMissing")
            await store.load()
            #expect(store.isLoaded && store.entries.map(\.expression) == ["unrelated"])
            #expect(try repository.engine.loadReviewEventCount() == 1)
            await store.shutdown(); try repository.shutdown()
        } catch { await store.shutdown(); try? repository.shutdown(); throw error }
    }

    @Test func aValidatedPullLeavesAFreshArchiveAbleToSaveOnlyItsEntry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-certified-sync-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let seed = folder.appendingPathComponent("seed")
        _ = try VocabularyBenchmarkFixture.seed(entries: 100, at: seed)
        let prepared = try VocabularyBenchmarkSyncSeed.prepare(from: seed.appendingPathComponent("primary.sqlite"),
            at: folder.appendingPathComponent("synced"))
        let fixture = try VocabularyBenchmarkFixture(seed: prepared, directory: folder.appendingPathComponent("cold"))
        do {
            let input = capture("after-pull")
            await fixture.store.save(input)
            #expect(!fixture.store.isLoaded && fixture.store.entries.isEmpty && fixture.store.lastEntryCommit != nil)
            #expect(await fixture.store.savedStatus(input) == true)
            let version = try #require(fixture.store.operationScope)
            #expect(try fixture.repository.engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_entries WHERE workspace_id=?",
                values: [.text(version.workspaceId)]) == 101)
            #expect(try fixture.repository.engine.loadReviewEventCount() == 10)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    private func capture(_ name: String, contextual: Bool = false) -> VocabularyCapture {
        .init(expression: name, dictionaryForm: name, language: .english, kind: .word, meaning: "A saved meaning",
            example: contextual ? .init(id: UUID(), text: "A synthetic example for \(name).", translation: "译文", ranges: [],
                completeness: .sentence, meaning: "Context meaning", createdAt: Date()) : nil)
    }
}
