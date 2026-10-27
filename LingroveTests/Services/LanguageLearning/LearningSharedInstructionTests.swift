import Foundation
import Testing
@testable import Lingrove

/// Sharing a model means sharing its native sequence, not just its settings. This fixture holds
/// the retiring worker open so the test can observe the otherwise brief cancellation boundary.
@MainActor
struct LearningSharedInstructionTests {
    @Test
    func sequentialExplanationAndExpressionBorrowOneExecutorWithSeparateContractsAndMetrics() async throws {
        let suite = "test.instructionServices.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LanguageLearningSettings(defaults: defaults)
        settings.explanation.localModel = "Qwen3.5-4B-Q4_K_M.gguf"
        settings.explanation.template = .qwen3
        settings.explanation.setResolvedTemplate(.qwen3, expectedIdentity: settings.explanation.contextIdentity)
        let core = HeldNative()
        let controller = LearningModelController(profile: settings.explanation,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            core: core, localModelURL: { _ in URL(fileURLWithPath: "/fixture.gguf") },
            templateResolver: { _ in .qwen3 })
        defer { controller.shutdownSync() }
        let metrics = PerformanceMetricsStore(userDefaults: defaults)
        let telemetry = LearningRequestTelemetry(metrics: metrics, trackingEnabled: { true })
        let explainer = LearningExplanationService(settings: settings, model: controller, telemetry: telemetry)
        let assist = ExpressionAssistService(model: controller, telemetry: telemetry)
        let explanation = try await explainer.generate(.init(target: "know", dictionaryForm: "know", language: .english,
            kind: .word, context: "Let me know.", ranges: [.init(NSRange(location: 7, length: 4))]), requestID: "req_explain")
        #expect(explanation.result.meaning == "告知")
        let request = try ExpressionAssistPolicy.request(query: "排除缓存", value: "We can't ?? yet.",
            range: NSRange(location: 9, length: 2), target: .english, explanation: .chinese)
        let expression = try await assist.generate(request, requestID: "req_expression")
        assist.recordDisplay(requestID: "req_expression")
        #expect(expression.candidates.first?.text == "rule out caching")
        #expect(core.started.count == 2 && core.maximumActive == 1)
        #expect(Set(metrics.entries.map(\.source)) == [.explanation, .expressionAssist])
        #expect(metrics.entries.allSatisfy { $0.outcome == .completed })
    }

    @Test
    func successorWaitsForNativeDrainAndSkipsObsoleteQueuedWork() async throws {
        let suite = "test.sharedInstruction.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = LearningModelSettings(role: .explanation, defaults: defaults)
        profile.localModel = "fixture.gguf"
        let core = HeldNative()
        let controller = LearningModelController(profile: profile,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            core: core, localModelURL: { _ in URL(fileURLWithPath: "/fixture.gguf") },
            templateResolver: { _ in .qwen3 })
        defer { core.release(); controller.shutdownSync() }
        let first = Task { try await controller.generate(prompt: "first", maxTokens: 1) }
        for _ in 0..<200 where core.started.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(core.started == ["first"])
        let second = Task { try await controller.generate(prompt: "second", maxTokens: 1) }
        for _ in 0..<10 { await Task.yield() }
        let third = Task { try await controller.generate(prompt: "third", maxTokens: 1) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(core.started == ["first"])
        core.release()
        #expect(try await third.value == "third")
        for task in [first, second] {
            do {
                _ = try await task.value
                Issue.record("Superseded work must cancel")
            } catch { #expect(error is CancellationError) }
        }
        #expect(core.started == ["first", "third"])
        #expect(core.maximumActive == 1)
    }

    @Test
    func preparationLeaseRejectsAnOlderRequestBeforeItCanGenerate() throws {
        let suite = "test.instructionLease.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = LearningModelController(profile: .init(role: .explanation, defaults: defaults),
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)), core: HeldNative())
        defer { controller.shutdownSync() }
        let older = controller.reserveInstructionRequest()
        let newer = controller.reserveInstructionRequest()
        #expect(throws: CancellationError.self) { try controller.validateInstructionRequest(older) }
        try controller.validateInstructionRequest(newer)
    }

    /// This fake deliberately does not return immediately on cancellation. A native decode also
    /// needs time to leave C++; the controller must await that exit before admitting its successor.
    private nonisolated final class HeldNative: LearningLocalExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var prompts: [String] = []
        private var active = 0
        private var peak = 0
        var started: [String] { lock.withLock { prompts } }
        var maximumActive: Int { lock.withLock { peak } }
        func release() { gate.signal() }
        func claim(_ operation: UUID) {}
        func invalidate() -> UUID { UUID() }
        func prepare(modelURL: URL, operationID: UUID, trace: LearningRequestContext?) throws {}
        // swiftlint:disable:next function_parameter_count
        func generate(modelURL: URL, template: LearningChatTemplate, prompt: String, maxTokens: Int,
                      operationID: UUID, trace: LearningRequestContext?, onLoad: (@Sendable (Int) -> Void)?,
                      onDelta: @Sendable (String) -> Void) throws -> String {
            lock.withLock { prompts.append(prompt); active += 1; peak = max(peak, active) }
            defer { lock.withLock { active -= 1 } }
            if prompt == "first" { _ = gate.wait(timeout: .now() + 3) }
            let output: String
            if prompt.contains("fill ONE") {
                output = "{\"candidates\":[{\"text\":\"rule out caching\",\"hint\":\"排除缓存\"}]}"
            } else if prompt.contains("Return ONLY one JSON object") {
                output = "{\"meaning\":\"告知\",\"explanation\":\"让某人知道。\"}"
            } else { output = prompt }
            onLoad?(0)
            onDelta(output)
            return output
        }
        func cancel(_ operation: UUID?) {}
        func unload(expectedLease: UUID?, trace: LearningRequestContext?) {}
        func shutdownSync() {}
    }
}

/// Opt-in quality smoke check uses an existing local general model with isolated preferences.
/// It never downloads weights or reads the writer's document; both cases are fixed test material.
@MainActor
struct ExpressionAssistNativeIntegrationTests {
    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_EXPRESSION_GGUF"] != nil))
    func existingGeneralModelFillsAnExpressionAndRecallsAConcept() async throws {
        let path = try #require(LingroveCompatibility.processEnvironment["LINGROVE_EXPRESSION_GGUF"])
        let suite = "test.nativeExpression.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = LearningModelSettings(role: .explanation, defaults: defaults)
        profile.localModel = URL(fileURLWithPath: path).lastPathComponent
        profile.setGenerationProfile(.init(maximumOutputTokens: 1_024))
        let controller = LearningModelController(profile: profile,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            localModelURL: { _ in URL(fileURLWithPath: path) })
        defer { controller.shutdownSync() }
        let service = ExpressionAssistService(model: controller, telemetry: LearningRequestTelemetry())
        let cases = [
            ("We still can't ?? yet.", "排除缓存是原因", ["rule out", "exclude", "eliminate", "dismiss"]),
            ("This is a classic case of ??.", "投入越多越不愿意放弃，即使继续并不划算的心理现象", ["sunk cost"])
        ]
        var rows: [[String: Any]] = []
        for (value, query, expected) in cases {
            let request = try ExpressionAssistPolicy.request(query: query, value: value,
                range: (value as NSString).range(of: "??"), target: .english, explanation: .chinese)
            let result = try await service.generate(request, requestID: RequestID.generate())
            #expect(!result.candidates.isEmpty)
            #expect(result.candidates.contains { candidate in expected.contains { candidate.text.lowercased().contains($0) } })
            #expect(result.candidates.allSatisfy { !$0.text.contains("<think>") && !$0.hint.isEmpty })
            #expect(result.candidates.allSatisfy { $0.hint.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } })
            rows.append(["source": value, "query": query,
                "candidates": result.candidates.map { ["text": $0.text, "hint": $0.hint] }])
        }
        if let output = LingroveCompatibility.processEnvironment["LINGROVE_EXPRESSION_REPORT"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }
}
