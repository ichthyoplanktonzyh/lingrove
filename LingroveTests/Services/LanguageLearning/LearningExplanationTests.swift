import Combine
import Foundation
import Testing
@testable import Lingrove

/// Uncooperative delayed replies prove UI isolation even when transport ignores cancellation.
@MainActor
struct LearningExplanationSessionTests {
    private func input(_ text: String) -> LearningExplanationInput {
        .init(target: text, dictionaryForm: text, language: .english, kind: .sentence, context: text,
            ranges: [.init(NSRange(location: 0, length: text.utf16.count))])
    }
    @Test func navigationIsIdleAndLateReplyCannotPublishIntoNewTarget() async throws {
        let fake = DelayedExplanation(), session = LearningExplanationSession(service: DelayedExplanation())
        session.setTarget(input("First sentence."))
        #expect(!session.isGenerating)
        let active = LearningExplanationSession(service: fake)
        active.setTarget(input("First sentence.")); active.explain()
        await wait { fake.pending.count == 1 }
        active.setTarget(input("Second sentence.")); active.explain()
        await wait { fake.pending.count == 2 }
        fake.complete(0)
        await Task.yield()
        #expect(active.record == nil && active.isGenerating)
        fake.complete(1)
        await wait { active.record != nil }
        #expect(active.record?.input.target == "Second sentence.")
        #expect(fake.displays == 1)
    }
    @Test func stopAndPreferenceChangesRejectUncooperativeReplies() async {
        let fake = DelayedExplanation(), session = LearningExplanationSession(service: DelayedExplanation())
        session.clear()
        let active = LearningExplanationSession(service: fake)
        active.setTarget(input("Sentence.")); active.explain()
        await wait { fake.pending.count == 1 }
        active.cancel(); fake.complete(0)
        await Task.yield()
        #expect(active.record == nil && !active.isGenerating && active.error == nil)
        active.explain()
        await wait { fake.pending.count == 2 }
        fake.changed.send(); fake.complete(1)
        await Task.yield()
        #expect(active.record == nil && !active.isGenerating)
    }

    @Test func regenerationKeepsThePreviousResultThroughStopAndFailureButResetsForANewTarget() async {
        let fake = DelayedExplanation(), active = LearningExplanationSession(service: fake)
        let target = input("Sentence.")
        let saved = LearningExplanationRecord(id: UUID(), input: target, language: .chinese,
            result: .init(meaning: "已有意思", explanation: "已有说明"), model: "fixture", createdAt: Date())
        active.setTarget(target, saved: saved)
        active.explain(refresh: true)
        await wait { fake.pending.count == 1 }
        #expect(active.isGenerating && active.record == saved)
        active.cancel()
        #expect(!active.isGenerating && active.record == saved && active.error == nil)
        fake.complete(0)
        await Task.yield()
        #expect(active.record == saved)
        active.explain(refresh: true)
        await wait { fake.pending.count == 2 }
        fake.pending[1].1.resume(throwing: NSError(domain: "fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Explanation failed."]))
        await wait { active.error != nil }
        #expect(!active.isGenerating && active.record == saved && active.error == "Explanation failed.")
        active.setTarget(input("A different sentence."))
        #expect(!active.isGenerating && active.record == nil && active.error == nil)
    }

    @Test func restoringASavedResultRequiresTheSelectedExplanationLanguage() {
        let service = DelayedExplanation()
        let active = LearningExplanationSession(service: service), target = input("Sentence.")
        func record(_ language: LearningLanguage) -> LearningExplanationRecord {
            .init(id: UUID(), input: target, language: language,
                result: .init(meaning: "Meaning", explanation: "Explanation"), model: "fixture", createdAt: Date())
        }
        active.setTarget(target, saved: record(.english))
        #expect(active.record == nil)
        let chinese = record(.chinese)
        active.setTarget(target, saved: chinese)
        #expect(active.record == chinese)
        active.clear()
    }
    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<500 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        #expect(predicate())
    }
    private final class DelayedExplanation: LearningExplanationGenerating {
        let changed = PassthroughSubject<Void, Never>()
        var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
        var language: LearningLanguage { .chinese }
        var isConfigured: Bool { true }
        var pending: [(LearningExplanationInput, CheckedContinuation<LearningExplanationRecord, any Error>)] = []
        var displays = 0
        func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
            try await withCheckedThrowingContinuation { pending.append((input, $0)) }
        }
        func complete(_ index: Int) {
            let (input, continuation) = pending[index]
            continuation.resume(returning: .init(id: UUID(), input: input, language: language,
                result: .init(meaning: "意思", explanation: "说明"), model: "fixture", createdAt: Date()))
        }
        func recordDisplay(requestID: String) { displays += 1 }
    }
}

/// A fake serialized executor tests the product service, settings, telemetry and cache together.
@MainActor
struct LearningExplanationServiceTests {
    @Test func independentProfileCachesOnlyCompleteResultsAndRecordsExplanationMetrics() async throws {
        let name = "lingrove.test.explanation.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let settings = LanguageLearningSettings(defaults: preferences,
            explanationCredentials: InMemoryOpenAICompatibleCredentialStore())
        let translation = settings.translation.snapshot
        settings.explanation.localModel = "Qwen3.5-4B-Q4_K_M.gguf"
        settings.explanation.template = .qwen3
        settings.explanation.setGenerationProfile(.init(maximumOutputTokens: 768))
        settings.explanation.setResolvedTemplate(.qwen3, expectedIdentity: settings.explanation.contextIdentity)
        let native = ExplanationNative()
        let controller = LearningModelController(profile: settings.explanation,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)), core: native,
            localModelURL: { _ in URL(fileURLWithPath: "/not-a-real-model.gguf") })
        defer { controller.shutdownSync() }
        let metrics = PerformanceMetricsStore(userDefaults: preferences)
        let service = LearningExplanationService(settings: settings, model: controller,
            telemetry: LearningRequestTelemetry(metrics: metrics, trackingEnabled: { true }))
        let input = LearningExplanationInput(target: "know", dictionaryForm: "know", language: .english, kind: .word,
            context: "Let me know.", ranges: [.init(NSRange(location: 7, length: 4))])
        let result = try await service.generate(input, requestID: "req_explain", refresh: false)
        service.recordDisplay(requestID: "req_explain")
        #expect(try await service.generate(input, requestID: "req_cached", refresh: false) == result)
        #expect(native.count == 1 && native.outputBudget == 768)
        #expect(metrics.entries.count == 1 && metrics.entries.first?.source == .explanation)
        #expect(metrics.entries.first?.outcome == .completed && metrics.entries.first?.displayMs != nil)
        #expect(settings.translation.snapshot == translation)
        _ = try await service.generate(input, requestID: "req_refresh", refresh: true)
        #expect(native.count == 2)
        settings.explanation.localModel = "renamed-specialist.gguf"
        settings.explanation.setResolvedTemplate(.translateGemma, expectedIdentity: settings.explanation.contextIdentity)
        await #expect(throws: (any Error).self) { try await service.generate(input, requestID: "req_specialist", refresh: true) }
        #expect(native.count == 2)
        let restored = LanguageLearningSettings(defaults: preferences)
        restored.explanation.localModel = "Qwen3.5-4B-Q4_K_M.gguf"
        #expect(restored.explanation.generationProfile.maximumOutputTokens == 768)
    }

    private nonisolated final class ExplanationNative: LearningLocalExecuting, @unchecked Sendable {
        // The production controller invokes this fixture from a detached worker; one lock owns counters.
        private let lock = NSLock()
        private var calls = 0, budget = 0
        var count: Int { lock.withLock { calls } }
        var outputBudget: Int { lock.withLock { budget } }
        func claim(_ operation: UUID) {}
        func invalidate() -> UUID { UUID() }
        func prepare(modelURL: URL, operationID: UUID, trace: LearningRequestContext?) throws {}
        // The fixture must implement the native executor's full generation signature.
        // swiftlint:disable:next function_parameter_count
        func generate(modelURL: URL, template: LearningChatTemplate, prompt: String, maxTokens: Int,
                      operationID: UUID, trace: LearningRequestContext?, onLoad: (@Sendable (Int) -> Void)?,
                      onDelta: @Sendable (String) -> Void) throws -> String {
            lock.withLock { calls += 1; budget = maxTokens }
            let text = "{\"meaning\":\"告知\",\"explanation\":\"let someone know 表示让某人知道。\"}"
            onLoad?(0); onDelta(text); return text
        }
        func cancel(_ operation: UUID?) {}
        func unload(expectedLease: UUID?, trace: LearningRequestContext?) {}
        func shutdownSync() {}
    }
}
