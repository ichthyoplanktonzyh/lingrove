import Foundation
import LingroveNotebook
import Testing
@testable import Lingrove

/// The real archive verifies merge direction, undo and late lookups using disposable state.
/// These tests never launch a model or discover the user's application/data directories.
@MainActor
struct VocabularySenseMergeTests {
    private func capture(_ text: String, meaning: String) -> VocabularyCapture {
        .init(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            meaning: meaning, meaningLanguage: .chinese,
            example: VocabularyPolicy.example(text: text, ranges: [(text as NSString).range(of: "bank")], language: .english))
    }

    @Test func favoriteStoresMeaningAndExplanationOnTheSenseWithoutMergingWording() async throws {
        let archive = VocabularyArchive(url: nil)
        var first = capture("The bank opens early.", meaning: "银行")
        first.explanation = .init(id: UUID(), input: LearningExplanationPolicy.input(first), language: .chinese,
            result: .init(meaning: "银行", explanation: "这里指金融机构。"), model: "fixture", createdAt: Date())
        _ = try await archive.save(first)
        let saved = try await archive.save(capture("I visited the bank.", meaning: "提供金融服务的机构"))
        let senses = saved.document.entries[0].senses
        #expect(senses.count == 2 && senses[0].meaning == "银行")
        #expect(senses[0].content?.first?.content == .text(.init(text: "这里指金融机构。")))
        #expect(senses[1].meaning == "提供金融服务的机构")
        #expect(try await archive.save(first).document.entries[0].senses.count == 2)
        await archive.shutdown()
    }

    @Test func mergeKeepsDestinationAndUndoRestoresMediaAndRelationships() async throws {
        let archive = VocabularyArchive(url: nil)
        let store = VocabularyStore(archive: archive)
        await store.save(capture("The bank opens early.", meaning: "银行"))
        await store.save(capture("I visited the bank.", meaning: "金融机构"))
        var document = try await archive.load().document
        let entryID = document.entries[0].id
        let target = document.entries[0].senses[0].id, source = document.entries[0].senses[1].id
        let image = try await archive.prepareImage(VocabularyImageTestFixture.png())
        document.entries[0].senses[0].content = []
        document.entries[0].senses[1].content = [.init(content: .image(image.reference, caption: "source only"))]
        document.entries[0].senses[1].note = "Source note"
        document.entries[0].senses[1].tags = ["Source tag"]
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Financial institution")])
        document.semantics.nodes = [node]
        document.semantics.mappings = [.init(nodeID: node.id, senseID: source)]
        let before = try await archive.commitWithImages(document, supplied: [image.reference.filename: image.data])
        await store.load()
        #expect(await store.mergeSenses(entryID: entryID, source: source, target: target,
            expectedRevision: before.revision))
        let merged = try #require(store.entries.first?.senses.first)
        #expect(merged.id == target && merged.meaning == "银行" && merged.content == [])
        #expect(merged.note.isEmpty && merged.tags.isEmpty && merged.examples.count == 2)
        #expect(store.semantics.nodes == [node] && store.semantics.mappings.isEmpty)
        #expect(store.canUndoSenseMerge)
        #expect(await store.undoLastSenseMerge() == .init(entryID: entryID, senseID: source))
        #expect(try await archive.load().document == before.document)
        #expect(try await archive.image(image.reference) == image.data)
        #expect(!store.canUndoSenseMerge)
        await store.shutdown()
    }

    @Test func staleUndoAndMergeCannotOverwriteAnInterveningWrite() async throws {
        let archive = VocabularyArchive(url: nil)
        _ = try await archive.save(capture("The bank opens early.", meaning: "银行"))
        let before = try await archive.save(capture("I visited the bank.", meaning: "金融机构"))
        let entry = before.document.entries[0]
        let (_, undo) = try await archive.mergeSensesWithUndo(entryID: entry.id, source: entry.senses[1].id,
            target: entry.senses[0].id, expectedRevision: before.revision)
        let newer = try await archive.save(capture("Another bank opened.", meaning: "银行"))
        await #expect(throws: VocabularyError.self) { try await archive.undoSenseMerge(undo) }
        await #expect(throws: VocabularyError.self) {
            try await archive.mergeSensesWithUndo(entryID: entry.id, source: newer.document.entries[0].senses[1].id,
                target: entry.senses[0].id, expectedRevision: before.revision)
        }
        #expect(try await archive.load().document == newer.document)
        await archive.shutdown()
    }

    @Test func delayedExplanationCannotReplaceClearedOrMergedContent() async throws {
        let archive = VocabularyArchive(url: nil)
        let first = capture("The bank opens early.", meaning: "银行")
        let second = capture("I visited the bank.", meaning: "金融机构")
        _ = try await archive.save(first)
        let initial = try await archive.save(second).document.entries[0]
        var edited = initial
        edited.senses[0].meaning = ""; edited.senses[0].content = []
        _ = try await archive.update(edited, basedOn: initial)
        let record = LearningExplanationRecord(id: UUID(), input: LearningExplanationPolicy.input(first), language: .chinese,
            result: .init(meaning: "Late meaning", explanation: "Late explanation"), model: "fixture", createdAt: Date())
        let cleared = try await archive.saveExplanation(record).document.entries[0].senses[0]
        #expect(cleared.meaning.isEmpty && cleared.content == [])
        _ = try await archive.mergeSenses(entryID: initial.id, source: initial.senses[1].id, target: initial.senses[0].id)
        let late = LearningExplanationRecord(id: UUID(), input: LearningExplanationPolicy.input(second), language: .chinese,
            result: .init(meaning: "Source meaning", explanation: "Source explanation"), model: "fixture", createdAt: Date())
        let retained = try await archive.saveExplanation(late).document.entries[0].senses[0]
        #expect(retained.meaning.isEmpty && retained.content == [] && retained.examples.count == 2)
        await archive.shutdown()
    }

    @Test func sameSentenceFromDifferentSourcesSurvivesMerge() throws {
        let now = Date()
        let first = try #require(capture("The bank opens early.", meaning: "银行").example)
        let second = try #require(capture("The bank opens early.", meaning: "金融机构").example)
        let source = VocabularySense(id: UUID(), meaning: "source", examples: [first], createdAt: now, updatedAt: now)
        let target = VocabularySense(id: UUID(), meaning: "target", examples: [second], createdAt: now, updatedAt: now)
        var entry = VocabularyEntry(id: UUID(), expression: "bank", dictionaryForm: "bank", language: .english,
            kind: .word, senses: [source, target], createdAt: now, updatedAt: now)
        try VocabularySenseEditingPolicy.merge(source: source.id, into: target.id, in: &entry, now: now)
        #expect(entry.senses[0].examples.count == 2)
        #expect(Set(entry.senses[0].examples.map(\.sourceID)).count == 2)
    }

    @Test func detailEditingRemovesOnlyTheChosenExampleAndPersists() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let store = VocabularyStore(archive: VocabularyArchive(url: url))
        await store.save(capture("The bank opens early.", meaning: "银行"))
        await store.save(capture("I visited the bank.", meaning: "金融机构"))
        let collected = try #require(store.entries.first)
        #expect(await store.mergeSenses(entryID: collected.id, source: collected.senses[1].id, target: collected.senses[0].id))
        let before = try #require(store.entries.first)
        var edited = before
        let removedID = try #require(edited.senses[0].examples.first?.id)
        edited.senses[0].examples.removeAll { $0.id == removedID }
        #expect(await store.update(edited, basedOn: before))
        let saved = try #require(store.entries.first)
        #expect(saved.senses[0].id == before.senses[0].id && saved.senses[0].meaning == before.senses[0].meaning)
        #expect(saved.senses[0].examples == before.senses[0].examples.filter { $0.id != removedID })
        await store.shutdown()
        let reopened = VocabularyArchive(url: url)
        #expect(try await reopened.load().document.entries == [saved])
        await reopened.shutdown()
    }
}
