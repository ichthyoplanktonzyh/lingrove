import Foundation
import LingroveNotebook
import Testing
@testable import Lingrove

/// Global tag deletion crosses the same scoped store/archive boundary as the editor. Private
/// SQLite fixtures verify persistence and draft reconciliation without touching learner data.
@Suite(.serialized)
@MainActor
struct VocabularyTagDeletionTests {
    @Test func removalPersistsAcrossAllSensesAndKeepsContentAndOtherTags() async throws {
        try await withFixture { archive, store, url in
            let original = try #require(store.entries.first { $0.expression == "bank" })
            var entry = original
            let image = try await store.prepareImage(VocabularyImageTestFixture.png())
            entry.senses[0].content = [.init(content: .text(.init(text: "Keep this explanation", bold: true))),
                .init(content: .image(image.reference, caption: "Keep this image"))]
            #expect(await store.update(entry, basedOn: original, importedImages: [image.reference.filename: image.data]))
            let before = try await archive.load()
            let scope = try #require(store.operationScope)
            let wrong = VocabularyOperationScope(workspaceId: scope.workspaceId, notebookId: scope.notebookId,
                revision: scope.revision, document: scope.document, generation: "different-generation")
            #expect(!(await store.removeTag("CLI Test", scope: wrong)))
            #expect(try await archive.load().document == before.document)
            #expect(await store.removeTag("CLI Test", scope: scope))
            let saved = try await archive.load()
            #expect(saved.revision == before.revision + 1)
            #expect(saved.document.sources == before.document.sources)
            #expect(saved.document.occurrences == before.document.occurrences)
            #expect(saved.document.interpretations == before.document.interpretations)
            #expect(saved.document.semantics == before.document.semantics)
            #expect(saved.document.classification == before.document.classification)
            #expect(saved.document.catalog.count == before.document.catalog.count)
            for prior in before.document.entries {
                let current = try #require(saved.document.entries.first { $0.id == prior.id })
                #expect(current.senses.count == prior.senses.count)
                for sense in prior.senses {
                    let kept = try #require(current.senses.first { $0.id == sense.id })
                    #expect(kept.tags == sense.tags.filter { $0 != "CLI Test" })
                    #expect(kept.meaning == sense.meaning && kept.note == sense.note && kept.content == sense.content)
                    #expect(kept.examples == sense.examples && kept.review == sense.review)
                }
            }
            #expect(store.entries.flatMap(\.senses).flatMap(\.tags).contains("cli test"))
            #expect(await store.image(image.reference) == image.data)
            #expect(await store.removeTag("CLI Test", scope: scope))
            #expect(try await archive.load().revision == saved.revision)
            let reopened = VocabularyArchive(url: url)
            #expect(try await reopened.load().document == saved.document)
            await reopened.shutdown()
        }
    }

    @Test func tagDeletionKeepsDraftEditsAndConcurrentFieldProtection() async throws {
        try await withFixture { archive, store, _ in
            let original = try #require(store.entries.first { $0.expression == "bank" })
            var baseline = original, draft = original
            draft.senses[0].note = "Unsaved editor note"
            draft.senses[0].tags = ["keep", "new tag"]
            var concurrent = original
            concurrent.senses[0].meaning = "A concurrent definition"
            #expect(await store.update(concurrent, basedOn: original))
            #expect(await store.removeTag("CLI Test", scope: store.operationScope))
            // Deletion is immediate even if the sheet is cancelled. It must not publish its note.
            let afterDeletion = try await archive.load()
            #expect(afterDeletion.document.entries.first { $0.id == original.id }?.senses[0].note == original.senses[0].note)
            VocabularySenseEditingPolicy.removeTag("CLI Test", from: &baseline)
            VocabularySenseEditingPolicy.removeTag("CLI Test", from: &draft)
            var conflict = draft
            conflict.senses[0].meaning = "Conflicting editor definition"
            #expect(!(await store.update(conflict, basedOn: baseline)))
            #expect(try await archive.load().document == afterDeletion.document)
            #expect(await store.update(draft, basedOn: baseline))
            let saved = try #require(store.entries.first { $0.id == original.id })
            #expect(saved.senses[0].note == "Unsaved editor note")
            #expect(saved.senses[0].meaning == "A concurrent definition")
            #expect(Set(saved.senses[0].tags) == ["keep", "new tag"])
            #expect(!store.entries.flatMap(\.senses).flatMap(\.tags).contains("CLI Test"))
        }
    }

    private func withFixture(_ body: (VocabularyArchive, VocabularyStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-tag-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: url), store = VocabularyStore(archive: archive)
        do {
            _ = try await store.addEntries([
                .init(expression: "bank", meaning: "Financial institution", note: "Original note", tags: ["CLI Test", "keep"],
                    example: "The bank is open."),
                .init(expression: "bank", meaning: "River edge", tags: ["CLI Test"], example: "We reached the bank."),
                .init(expression: "defer", meaning: "Postpone", tags: ["CLI Test", "other"], example: "We defer the decision."),
                .init(expression: "quiet", meaning: "Silent", tags: ["cli test"])
            ])
            try await body(archive, store, url)
            await store.shutdown()
        } catch { await store.shutdown(); throw error }
    }
}
