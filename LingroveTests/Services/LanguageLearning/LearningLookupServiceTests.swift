import Foundation
import Testing
@testable import Lingrove

/// The real service/controller execute against a serialized native fixture. These checks catch
/// accidental extra generation, task-cache collisions and changes to the accepted pair in details.
@MainActor
struct LearningLookupServiceTests {
    @Test func basicAndDetailsUseOneGeneralModelWithSeparateAnchoredCaches() async throws {
        let name = "lingrove.test.lookup.service.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageLearningSettings(defaults: defaults)
        settings.explanationLanguage = .chinese
        settings.explanation.localModel = "Qwen3.5-4B-Q4_K_M.gguf"
        settings.explanation.template = .qwen3
        settings.explanation.setGenerationProfile(.init(maximumOutputTokens: 768))
        settings.explanation.setResolvedTemplate(.qwen3, expectedIdentity: settings.explanation.contextIdentity)
        let native = LookupNative()
        let controller = LearningModelController(profile: settings.explanation,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)), core: native,
            localModelURL: { _ in URL(fileURLWithPath: "/fixture.gguf") })
        defer { controller.shutdownSync() }
        let service = LearningExplanationService(settings: settings, model: controller, telemetry: LearningRequestTelemetry())
        let sentence = "He sat on the bank of the river."
        let target = LearningExplanationInput(target: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            context: sentence, ranges: [.init((sentence as NSString).range(of: "bank"))], contextKind: .sentence)
        let input = LearningLookupInput(target: target, translationLanguage: .chinese)
        var saved: [LearningExplanationRecord] = []
        service.didExplain = { saved.append($0) }

        let basic = try await service.lookup(input, requestID: "basic", refresh: false)
        #expect(basic.result.meaning == "河岸" && native.prompts.count == 1 && saved.isEmpty)
        #expect(native.budgets == [512])
        #expect(try await service.lookup(input, requestID: "cached", refresh: false) == basic)
        #expect(native.prompts.count == 1)
        let details = try await service.explainLookup(basic, requestID: "details", refresh: false)
        #expect(native.prompts.count == 2 && native.budgets == [512, 768])
        #expect(details.result.meaning == basic.result.meaning && saved.count == 1)
        #expect(native.prompts[1].contains("accepted_sentence_translation") && native.prompts[1].contains("他坐在河岸上。"))
        #expect(try await service.explainLookup(basic, requestID: "detailsCached", refresh: false) == details)
        #expect(native.prompts.count == 2)

        let changed = LearningLookupRecord(input: input, language: .chinese,
            result: .init(meaning: "岸边", sentenceTranslation: "他坐在河边。"), model: basic.model, createdAt: Date())
        let second = try await service.explainLookup(changed, requestID: "differentAnchor", refresh: false)
        #expect(native.prompts.count == 3 && second.result.meaning == "岸边")
        #expect(native.prompts[2].contains("岸边") && native.prompts[2].contains("他坐在河边。"))

        var example = VocabularyPolicy.example(text: sentence,
            ranges: [(sentence as NSString).range(of: "bank")], language: .english)
        example?.translation = basic.result.sentenceTranslation
        example?.translationLanguage = .chinese
        example?.meaning = basic.result.meaning
        example?.meaningOrigin = .ai
        let capture = VocabularyCapture(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            meaning: basic.result.meaning, meaningLanguage: .chinese, example: example, allowsExplanationEnrichment: false)
        let legacyInput = LearningExplanationPolicy.input(capture)
        _ = try await service.generate(legacyInput, requestID: "oldFullResult", refresh: true)
        #expect(service.cached(legacyInput)?.result.meaning == "旧释义")
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        store.enrichCapture = service.enrich
        await store.save(capture)
        let savedExample = try #require(store.entries.first?.examples.first)
        #expect(savedExample.meaning == "河岸" && savedExample.translation == "他坐在河岸上。")
        #expect(savedExample.explanations.isEmpty, "A legacy full result cannot replace the newly accepted lookup pair")
    }
}

private nonisolated final class LookupNative: LearningLocalExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPrompts: [String] = []
    private var recordedBudgets: [Int] = []
    var prompts: [String] { lock.withLock { recordedPrompts } }
    var budgets: [Int] { lock.withLock { recordedBudgets } }
    func claim(_ operation: UUID) {}
    func invalidate() -> UUID { UUID() }
    func prepare(modelURL: URL, operationID: UUID, trace: LearningRequestContext?) throws {}
    // swiftlint:disable:next function_parameter_count
    func generate(modelURL: URL, template: LearningChatTemplate, prompt: String, maxTokens: Int,
                  operationID: UUID, trace: LearningRequestContext?, onLoad: (@Sendable (Int) -> Void)?,
                  onDelta: @Sendable (String) -> Void) throws -> String {
        lock.withLock { recordedPrompts.append(prompt); recordedBudgets.append(maxTokens) }
        let raw = prompt.contains("Return ONLY one JSON object")
            ? "{\"meaning\":\"旧释义\",\"explanation\":\"旧解释\"}"
            : prompt.contains("Return ONLY {\"explanation\"")
            ? "{\"explanation\":\"bank 在这里是名词，指河流边缘的陆地。\"}"
            : "{\"meaning\":\"河岸\",\"sentence_translation\":\"他坐在河岸上。\"}"
        onLoad?(0); onDelta(raw)
        return raw
    }
    func cancel(_ operation: UUID?) {}
    func unload(expectedLease: UUID?, trace: LearningRequestContext?) {}
    func shutdownSync() {}
}
