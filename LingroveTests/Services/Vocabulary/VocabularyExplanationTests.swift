import Foundation
import Testing
@testable import Lingrove

/// Isolated archives exercise opt-in adoption and contextual annotations without user data.
@MainActor
struct VocabularyExplanationTests {
    private func capture(_ text: String = "Let me know.") -> VocabularyCapture {
        .init(expression: "know", dictionaryForm: "know", language: .english, kind: .word,
            example: VocabularyPolicy.example(text: text, ranges: [(text as NSString).range(of: "know")], language: .english))
    }
    private func record(_ capture: VocabularyCapture, language: LearningLanguage = .chinese) -> LearningExplanationRecord {
        .init(id: UUID(), input: LearningExplanationPolicy.input(capture), language: language,
            result: .init(meaning: "告知", explanation: "let someone know 表示让某人知道。"), model: "fixture", createdAt: Date())
    }

    @Test func explanationDoesNotCreateFavoritesOrOverwriteMeaningsAndNotes() async throws {
        let archive = VocabularyArchive(url: nil), store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let capture = capture(), result = record(capture)
        #expect(try await archive.saveExplanation(result).document.entries.isEmpty)
        await store.save(capture)
        var baseline = try #require(store.entries.first), edited = baseline
        edited.senses[0].note = "User note"; edited.senses[0].examples[0].meaning = "My meaning"
        #expect(await store.update(edited, basedOn: baseline))
        await store.saveExplanation(result)
        baseline = try #require(store.entries.first)
        #expect(baseline.senses[0].note == "User note" && baseline.examples[0].meaning == "My meaning")
        #expect(baseline.explanations == [result])
        #expect(await store.adoptExplanation(result, at: .init(entryID: baseline.id, senseID: baseline.senses[0].id,
                exampleID: baseline.examples[0].id)))
        #expect(store.entries[0].examples[0].meaning == "告知" && store.entries[0].senses[0].note == "User note")
        #expect(store.contains(capture), "Adopting a meaning must not change favorite identity")
        await store.save(capture)
        #expect(store.entries[0].examples.count == 1 && store.entries[0].examples[0].meaning == "告知")
    }

    @Test func adoptingAnotherLanguageKeepsTheUsageAndSenseIdentity() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        var first = capture(), second = first
        first.example?.translationLanguage = .chinese
        second.example?.translationLanguage = .japanese
        await store.save(first); await store.save(second)
        let entry = try #require(store.entries.first)
        #expect(entry.examples.count == 1)
        let result = record(second)
        #expect(await store.adoptExplanation(result,
            at: .init(entryID: entry.id, senseID: entry.senses[0].id, exampleID: entry.examples[0].id)))
        #expect(store.entries[0].examples[0].meaning == result.result.meaning)
        #expect(store.entries[0].senses[0].id == entry.senses[0].id && store.entries[0].examples[0].id == entry.examples[0].id)
    }

    @Test func adoptingAnotherLanguagePreservesOriginalStandaloneMeaning() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let capture = VocabularyCapture(expression: "know", dictionaryForm: "know", language: .english, kind: .word,
            meaning: "知道", meaningLanguage: .chinese)
        await store.save(capture)
        let entry = try #require(store.entries.first)
        let result = LearningExplanationRecord(id: UUID(), input: LearningExplanationPolicy.input(capture), language: .english,
            result: .init(meaning: "be aware of", explanation: "A verb describing knowledge."), model: "fixture", createdAt: Date())
        #expect(await store.adoptExplanation(result, at: .init(entryID: entry.id, senseID: entry.senses[0].id, exampleID: nil)))
        #expect(store.entries[0].senses[0].meaningLanguage == .english)
        #expect(store.entries[0].senses[0].standaloneMeanings.contains(.init(text: "知道", language: .chinese)))
        #expect(store.entries[0].senses[0].standaloneMeanings.contains(.init(text: "be aware of", language: .english)))
    }

    @Test func uncollectingRetainsKnowledgeAndEditingPrunesOnlyTheChangedExplanation() async throws {
        let archive = VocabularyArchive(url: nil)
        let first = capture(), second = capture("I know the answer.")
        _ = try await archive.save(first); _ = try await archive.save(second)
        _ = try await archive.saveExplanation(record(first)); _ = try await archive.saveExplanation(record(second))
        let removed = try await archive.remove(first)
        #expect(removed.document.collectedEntries[0].explanations?.map(\.input.context) == [second.example!.text])
        _ = try await archive.saveExplanation(record(first))
        let baseline = try #require(try await archive.load().document.collectedEntries.first)
        var edited = baseline
        edited.senses[0].examples[0].text = "The user changed this example."; edited.senses[0].examples[0].ranges = []
        let updated = try await archive.update(edited, basedOn: baseline)
        #expect(updated.document.collectedEntries[0].explanations == nil)
        #expect(!LearningExplanationPolicy.isValid(LearningExplanationPolicy.input(
            LearningExplanationPolicy.capture(updated.document.collectedEntries[0], example: edited.senses[0].examples[0]))))
    }

    @Test func floatingSessionLoadsSavedAnnotationBeforeModelConfiguration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite"), capture = capture(), result = record(capture)
        let archive = VocabularyArchive(url: url)
        _ = try await archive.save(capture); _ = try await archive.saveExplanation(result)
        let coldStore = VocabularyStore(archive: VocabularyArchive(url: url))
        let name = "lingrove.test.savedExplanation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageLearningSettings(defaults: defaults)
        settings.explanationLanguage = .chinese
        let controller = LearningModelController(profile: settings.explanation,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)))
        defer { controller.shutdownSync() }
        let service = LearningExplanationService(settings: settings, model: controller, telemetry: LearningRequestTelemetry())
        service.loadPersisted = { input, language in
            await coldStore.load()
            return coldStore.explanation(for: input, language: language)
        }
        #expect(!service.isConfigured && !coldStore.isLoaded)
        let session = LearningExplanationSession(service: service)
        session.setTarget(result.input)
        for _ in 0..<500 where session.record == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(session.record == result && coldStore.isLoaded)
        #expect(try await service.generate(result.input, requestID: "req_saved", refresh: false) == result)
    }

    @Test func oldArchiveAndNewAnnotationsBothReopenLosslessly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: url)
        let capture = capture(), result = record(capture)
        _ = try await archive.save(capture)
        #expect(try await VocabularyArchive(url: url).load().document.entries[0].explanations == nil)
        _ = try await archive.saveExplanation(result)
        #expect(try await VocabularyArchive(url: url).load().document.entries[0].explanations == [result])
    }
}
