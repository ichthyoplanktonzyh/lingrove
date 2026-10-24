import Foundation
import Combine
import Testing
@testable import Lingrove

/// Resource policy tests never load a real GGUF. Empty selections and loopback-free fake endpoints
/// prove task eligibility and residency transitions independently from native model performance.
@MainActor
struct LearningModelResidencyTests {
    @Test
    func independentTasksReleaseOnGlobalPauseAndTranslationDisable() async throws {
        let name = "lingrove.test.learningResidency.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let app = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        app.setGloballyEnabled(true)
        app.languageLearning.translationEnabled = true
        let models = LearningModelCollection(settings: app.languageLearning,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)), appSettings: app)
        #expect(models.translation.residency == .warm)
        #expect(models.explanation.residency == .onDemand)
        app.languageLearning.translationEnabled = false
        models.reconcileResources()
        #expect(models.translation.residency == .released)
        #expect(models.explanation.residency == .onDemand)
        app.setGloballyEnabled(false)
        models.reconcileResources()
        #expect(models.translation.residency == .released)
        do {
            _ = try await models.translation.generate(prompt: "fixture", maxTokens: 1)
            Issue.record("Disabled work must cancel")
        } catch { #expect(error is CancellationError) }
        app.setGloballyEnabled(true)
        app.languageLearning.translationEnabled = true
        models.reconcileResources()
        #expect(models.translation.residency == .warm)
        models.shutdownSync()
    }

    @Test
    func sharedLowPowerMonitorImmediatelyChangesBothResidencies() async throws {
        let name = "lingrove.test.learningPowerMonitor.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let app = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        app.setGloballyEnabled(true)
        app.setLowPowerModeAutoDisableEnabled(true)
        app.languageLearning.translationEnabled = true
        let monitor = FakePower()
        let models = LearningModelCollection(settings: app.languageLearning,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)), appSettings: app, lowPower: monitor)
        #expect(models.translation.residency == .warm && models.explanation.residency == .onDemand)
        monitor.update(true)
        await waitUntil { models.translation.residency == .released && models.explanation.residency == .released }
        monitor.update(false)
        await waitUntil { models.translation.residency == .warm && models.explanation.residency == .onDemand }
        models.shutdownSync()
    }

    @Test
    func explanationIdleReleasesNativeContextAndItsNextRequestCanReload() async throws {
        let name = "lingrove.test.learningIdle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let profile = LearningModelSettings(role: .explanation, defaults: defaults)
        let core = FakeNative()
        let controller = LearningModelController(profile: profile,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            core: core, localModelURL: { _ in URL(fileURLWithPath: "/fixture.gguf") })
        profile.localModel = "fixture.gguf"
        controller.idleReleaseDelay = .milliseconds(20)
        controller.applyResidency(.onDemand, generationAllowed: true)
        let observer = LearningRequestTelemetry()
        let output = try await LearningRequestTrace.$requestID.withValue("req_native_fixture") {
            try await observer.perform(source: .explanation, profile: profile.snapshot) {
                try await controller.generate(prompt: "fixture", maxTokens: 1)
            }
        }
        #expect(output == "Hello")
        #expect(core.recordedTrace?.requestID == "req_native_fixture")
        #expect(core.recordedTrace?.source == .explanation)
        #expect(controller.status == String(localized: "Ready", table: "Learning"))
        await waitUntil { core.unloadCount == 1 }
        #expect(controller.status == String(localized: "Not loaded", table: "Learning"))
        #expect(try await controller.generate(prompt: "fixture", maxTokens: 1) == "Hello")
        #expect(core.loadCount == 2)
        controller.applyResidency(.released, generationAllowed: false)
        await waitUntil { core.unloadCount == 2 }
        controller.shutdownSync()
    }

    @Test
    func cancelledLoadWithoutDeliveredReadyEventStillReleasesNativeMemory() async throws {
        let name = "lingrove.test.cancelledResident.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let profile = LearningModelSettings(role: .explanation, defaults: defaults)
        let core = FakeNative(failAfterLoad: true)
        let controller = LearningModelController(profile: profile,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            core: core, localModelURL: { _ in URL(fileURLWithPath: "/fixture.gguf") })
        profile.localModel = "fixture.gguf"
        controller.idleReleaseDelay = .milliseconds(20)
        controller.applyResidency(.onDemand, generationAllowed: true)
        do {
            _ = try await controller.generate(prompt: "fixture", maxTokens: 1)
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(core.loadCount == 1)
        await waitUntil { core.unloadCount == 1 }
        controller.shutdownSync()
    }

    @Test
    func queuedWarmupChecksLiveEligibilityBeforeStartingNativeLoad() async throws {
        let name = "lingrove.test.queuedWarmup.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let profile = LearningModelSettings(role: .translation, defaults: defaults)
        let core = FakeNative()
        let controller = LearningModelController(profile: profile,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            core: core, localModelURL: { _ in URL(fileURLWithPath: "/fixture.gguf") })
        profile.localModel = "fixture.gguf"
        var eligible = true
        controller.warmupEligibility = { eligible }
        controller.applyResidency(.warm, generationAllowed: true)
        eligible = false
        for _ in 0..<5 { await Task.yield() }
        #expect(core.loadCount == 0)
        controller.shutdownSync()
    }

    @Test
    func styleAndSamplerEditsCancelRequestsWithoutEvictingWarmWeights() async throws {
        let name = "lingrove.test.parameterResidency.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let profile = LearningModelSettings(role: .translation, defaults: defaults)
        let core = FakeNative()
        let controller = LearningModelController(profile: profile,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            core: core, localModelURL: { _ in URL(fileURLWithPath: "/fixture.gguf") })
        profile.localModel = "fixture.gguf"
        controller.applyResidency(.warm, generationAllowed: true)
        await waitUntil { core.loadCount == 1 }
        for _ in 0..<20 { await Task.yield() }
        profile.setGenerationProfile(.init(style: .init(register: .formal), sampling: .init(topK: 8)))
        controller.applyResidency(.warm, generationAllowed: true)
        #expect(try await controller.generate(prompt: "fixture", maxTokens: 1) == "Hello")
        #expect(core.loadCount == 1 && core.unloadCount == 0)
        profile.localModel = "another.gguf"
        profile.setGenerationProfile(.init(sampling: .init(topK: 12)))
        await waitUntil { core.unloadCount == 1 }
        controller.shutdownSync()
    }

    @Test(arguments: [LearningChatTemplate.hyMT, .translateGemma])
    func firstAutomaticRequestWaitsForMetadataAndKeepsItsSavedStyle(_ template: LearningChatTemplate) async throws {
        let name = "lingrove.test.firstStyledRequest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data("GGUF".utf8)
        func integer(_ value: UInt64, _ bytes: Int) {
            for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
        }
        func string(_ value: String) { integer(UInt64(value.utf8.count), 8); data.append(Data(value.utf8)) }
        integer(3, 4); integer(0, 8); integer(2, 8)
        string("general.architecture"); integer(8, 4); string(template == .hyMT ? "hunyuan-dense" : "gemma3")
        string("general.name"); integer(8, 4); string(template == .hyMT ? "Hy-MT" : "TranslateGemma")
        try data.write(to: url)
        let profile = LearningModelSettings(role: .translation, defaults: defaults)
        profile.localModel = "renamed.gguf"
        profile.setGenerationProfile(.init(style: .init(register: .formal)))
        let controller = LearningModelController(profile: profile,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            core: FakeNative(), localModelURL: { _ in url })
        let request = try await controller.translationPlan(input: .init(source: "你好"),
            sourceLanguage: .chinese, targetLanguage: .english, output: 128)
        #expect(request.prompt.contains("formal written register") == (template == .hyMT))
        #expect(profile.snapshot.translationStyle.register == .formal)
        #expect(profile.recommendedSampling == LearningInstructionSampling.forTemplate(template).values)
        controller.shutdownSync()
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Resource transition did not finish")
    }

    private final class FakePower: SuggestionLowPowerModeProviding {
        var isLowPowerModeEnabled = false
        let changes = PassthroughSubject<Bool, Never>()
        var lowPowerModeChanges: AnyPublisher<Bool, Never> { changes.eraseToAnyPublisher() }
        func update(_ value: Bool) { isLowPowerModeEnabled = value; changes.send(value) }
    }

    /// Native callbacks run on a detached queue, so even this counter fixture uses a lock. It
    /// models leases and residency only, not tokenization or the production implementation's locks.
    private nonisolated final class FakeNative: LearningLocalExecuting, @unchecked Sendable {
        let lock = NSLock()
        private var lease = UUID()
        private var resident = false
        private var loads = 0
        private var unloads = 0
        private var trace: LearningRequestContext?
        var recordedTrace: LearningRequestContext? { lock.withLock { trace } }
        private let failAfterLoad: Bool
        init(failAfterLoad: Bool = false) { self.failAfterLoad = failAfterLoad }
        var loadCount: Int { lock.withLock { loads } }
        var unloadCount: Int { lock.withLock { unloads } }
        func claim(_ id: UUID) { lock.withLock { lease = id } }
        func invalidate() -> UUID { lock.withLock { lease = UUID(); return lease } }
        func prepare(modelURL: URL, operationID: UUID, trace: LearningRequestContext?) throws {
            try lock.withLock {
                guard lease == operationID else { throw CancellationError() }
                self.trace = trace
                if !resident { resident = true; loads += 1 }
            }
        }
        // The fake implements the same native boundary so cancellation exercises real controller policy.
        // swiftlint:disable:next function_parameter_count
        func generate(
            modelURL: URL, template: LearningChatTemplate, prompt: String, maxTokens: Int,
            operationID: UUID, trace: LearningRequestContext?, onLoad: (@Sendable (Int) -> Void)?,
            onDelta: @Sendable (String) -> Void
        ) throws -> String {
            try prepare(modelURL: modelURL, operationID: operationID, trace: trace)
            if failAfterLoad { throw CancellationError() }
            onLoad?(0); onDelta("Hello"); return "Hello"
        }
        func cancel(_ operation: UUID?) {}
        func unload(expectedLease: UUID?, trace: LearningRequestContext?) {
            lock.withLock {
                guard expectedLease == nil || expectedLease == lease, resident else { return }
                resident = false; unloads += 1
            }
        }
        func shutdownSync() { unload(expectedLease: nil, trace: nil) }
    }

    @Test
    func lowPowerDecisionReleasesBothNativeRolesAndRecoveryRestoresTheirPolicies() {
        for keepWarm in [false, true] {
            #expect(LocalRuntimeResidencyPolicy.residency(usesLocalModel: true, enabled: true,
                paused: true, keepWarm: keepWarm) == .released)
            #expect(LocalRuntimeResidencyPolicy.residency(usesLocalModel: true, enabled: true,
                paused: false, keepWarm: keepWarm) == (keepWarm ? .warm : .onDemand))
            #expect(LocalRuntimeResidencyPolicy.residency(usesLocalModel: false, enabled: true,
                paused: false, keepWarm: keepWarm) == .released)
        }
    }
}
