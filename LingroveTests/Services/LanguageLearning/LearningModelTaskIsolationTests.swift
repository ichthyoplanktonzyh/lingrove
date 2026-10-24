import Foundation
import Testing
@testable import Lingrove

/// Controllers receive a synthetic installed list and a counting native boundary. These tests
/// exercise real selection/preflight policy without reading user GGUFs or starting a model.
@MainActor
struct LearningModelTaskIsolationTests {
    @Test func renamedSpecialistCannotWarmUpOrGenerateAnExplanation() async throws {
        let name = "lingrove.test.renamedTaskGuard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let profile = LearningModelSettings(role: .explanation, defaults: defaults)
        profile.localModel = "renamed.gguf"
        let core = NoCallsNative()
        let controller = LearningModelController(profile: profile, client: OpenAICompatibleAPIClient(), core: core,
            localModelURL: { _ in URL(fileURLWithPath: "/renamed.gguf") }, modelOptionsProvider: { [] },
            templateResolver: { _ in .hyMT })
        defer { controller.shutdownSync() }
        controller.applyResidency(.warm, generationAllowed: true)
        await controller.prepare()
        do {
            _ = try await controller.generate(prompt: "must not run", maxTokens: 1)
            Issue.record("Metadata identifies this renamed file as a translation specialist.")
        } catch { #expect(error is LearningFailure) }
        #expect(core.operationCount == 0)
    }

    @Test(arguments: [LearningModelRole.translation, .explanation])
    func onlyTaskModelsAndExplicitCustomChoicesEnterPickers(_ role: LearningModelRole) throws {
        let name = "lingrove.test.taskCandidates.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let profile = LearningModelSettings(role: role, defaults: defaults)
        profile.localModel = "explicit-custom.gguf"
        let all = LocalModelCatalog.entries.map {
            RuntimeModelOption(filename: $0.filename, url: URL(fileURLWithPath: "/models/" + $0.filename))
        } + ["explicit-custom.gguf", "unassigned.gguf"].map {
            RuntimeModelOption(filename: $0, url: URL(fileURLWithPath: "/models/" + $0))
        }
        let controller = LearningModelController(profile: profile, client: OpenAICompatibleAPIClient(),
            core: NoCallsNative(), localModelURL: { _ in throw CancellationError() }, modelOptionsProvider: { all })
        defer { controller.shutdownSync() }
        #expect(controller.availableModels.contains { $0.filename == "explicit-custom.gguf" })
        #expect(!controller.availableModels.contains { $0.filename == "unassigned.gguf" })
        for option in controller.availableModels where option.filename != "explicit-custom.gguf" {
            #expect(LocalModelCatalog.descriptor(for: option.filename)?.task == LocalModelTask(role))
        }
    }

    @Test func incompatibleSavedChoicesSurviveAndNeverResolveLoadOrGenerate() async throws {
        let name = "lingrove.test.taskPreflight.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let profile = LearningModelSettings(role: .translation, defaults: defaults)
        let filename = "gemma-4-E2B.i1-Q6_K.gguf"
        profile.localModel = filename
        profile.batteryProfile = .local(filename)
        profile.pluggedInProfile = .local("Qwen3.5-4B-Q4_K_M.gguf")
        let before = [profile.localModel, profile.batteryProfile.localModel, profile.pluggedInProfile.localModel]
        let core = NoCallsNative()
        var resolutions = 0
        let controller = LearningModelController(profile: profile, client: OpenAICompatibleAPIClient(), core: core,
            localModelURL: { _ in resolutions += 1; throw CancellationError() }, modelOptionsProvider: { [] })
        defer { controller.shutdownSync() }
        controller.applyResidency(.warm, generationAllowed: true)
        await controller.prepare()
        do {
            _ = try await controller.generate(prompt: "must not run", maxTokens: 1)
            Issue.record("An incompatible model must be rejected before execution.")
        } catch { #expect(error is LearningFailure) }
        #expect(resolutions == 0 && core.operationCount == 0)
        #expect([profile.localModel, profile.batteryProfile.localModel, profile.pluggedInProfile.localModel] == before)
        let reopened = LearningModelSettings(role: .translation, defaults: defaults)
        #expect([reopened.localModel, reopened.batteryProfile.localModel, reopened.pluggedInProfile.localModel] == before)
    }

    private nonisolated final class NoCallsNative: LearningLocalExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private var operations = 0
        var operationCount: Int { lock.withLock { operations } }
        func claim(_ operation: UUID) { lock.withLock { operations += 1 } }
        func invalidate() -> UUID { UUID() }
        func prepare(modelURL: URL, operationID: UUID, trace: LearningRequestContext?) throws {
            lock.withLock { operations += 1 }
        }
        func generate(modelURL: URL, template: LearningChatTemplate, prompt: String, maxTokens: Int,
                      operationID: UUID, trace: LearningRequestContext?, onLoad: (@Sendable (Int) -> Void)?,
                      onDelta: @Sendable (String) -> Void) throws -> String {
            lock.withLock { operations += 1 }
            return "unexpected"
        }
        func cancel(_ operation: UUID?) {}
        func unload(expectedLease: UUID?, trace: LearningRequestContext?) {}
        func shutdownSync() {}
    }
}
