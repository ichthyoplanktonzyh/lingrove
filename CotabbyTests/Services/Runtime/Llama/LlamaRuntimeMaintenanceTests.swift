import Foundation
import Testing
@testable import Cotabby

/// Models a cache reset parked behind native work without loading a GGUF. Tests must be able to
/// make progress on MainActor while that reset is parked, and a superseded caller cannot let a
/// newer reset overtake it. The probe has a timeout so regressions fail instead of deadlocking.
@MainActor
struct LlamaRuntimeMaintenanceTests {
    private static var retainedManagers: [LlamaRuntimeManager] = []

    @Test func blockedNativeCacheResetLeavesTheMainActorResponsive() async throws {
        let probe = MaintenanceProbe()
        let fixture = try makeManager(probe: probe)
        defer { probe.resume.signal(); try? FileManager.default.removeItem(at: fixture.directory) }
        let reset = Task { @MainActor in await fixture.manager.resetPromptCache() }
        let started = await Task.detached { probe.started.wait(timeout: .now() + 3) == .success }.value
        #expect(started)
        // Reaching this assertion while native work is still parked represents the UI's next
        // event/paint turn. With the former synchronous manager method, it arrives after timeout.
        #expect(!probe.snapshot.onMainThread)
        #expect(probe.snapshot.finished == 0)
        probe.resume.signal()
        await reset.value
        #expect(probe.snapshot.finished == 1)
    }

    @Test func aCancelledResetCallerStillOrdersLaterMaintenance() async throws {
        let probe = MaintenanceProbe()
        let fixture = try makeManager(probe: probe)
        defer { probe.resume.signal(); try? FileManager.default.removeItem(at: fixture.directory) }
        let first = Task { @MainActor in await fixture.manager.resetPromptCache() }
        let firstStarted = await Task.detached { probe.started.wait(timeout: .now() + 3) == .success }.value
        #expect(firstStarted)
        first.cancel()
        let second = Task { @MainActor in await fixture.manager.resetPromptCache() }
        for _ in 0..<20 { await Task.yield() }
        #expect(probe.snapshot.calls == 1)
        probe.resume.signal()
        let secondStarted = await Task.detached { probe.started.wait(timeout: .now() + 3) == .success }.value
        #expect(secondStarted)
        #expect(probe.snapshot.calls == 2 && probe.snapshot.finished == 1)
        #expect(probe.snapshot.maximumConcurrent == 1)
        probe.resume.signal()
        await first.value; await second.value
        #expect(probe.snapshot.finished == 2)
    }

    @Test(arguments: ["prepare", "generate", "prefill"])
    func nativeEntryWaitsForQueuedCacheMaintenance(_ kind: String) async throws {
        let probe = MaintenanceProbe()
        let fixture = try makeManager(probe: probe)
        defer { probe.resume.signal(); try? FileManager.default.removeItem(at: fixture.directory) }
        let reset = Task { @MainActor in await fixture.manager.resetPromptCache() }
        let started = await Task.detached { probe.started.wait(timeout: .now() + 3) == .success }.value
        #expect(started)
        var finished = false
        let request = Task { @MainActor in
            defer { finished = true }
            let options = LlamaGenerationOptions(maxPredictionTokens: 1, temperature: 0, topK: 1,
                topP: 1, minP: 0, repetitionPenalty: 1, seed: nil)
            do {
                switch kind {
                case "generate": _ = try await fixture.manager.generate(prompt: "fixture", options: options)
                case "prefill": try await fixture.manager.prefill(prompt: "fixture", options: options)
                default: try await fixture.manager.prepare()
                }
            } catch { /* No fixture GGUF: resolution must fail only after the reset barrier. */ }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!finished)
        probe.resume.signal()
        await reset.value; await request.value
        #expect(finished)
    }

    private struct Fixture {
        let manager: LlamaRuntimeManager
        let directory: URL
    }

    private func makeManager(probe: MaintenanceProbe) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CacheReset-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = LlamaRuntimeConfiguration(runtimeDirectoryPath: directory.path,
            preferredModelNames: [], contextWindowTokens: 512, batchSize: 128, gpuLayerCount: 0)
        let manager = LlamaRuntimeManager(configuration: configuration, runtimeLocator: BundledRuntimeLocator(),
            cacheResetOperation: { probe.run() })
        Self.retainedManagers.append(manager)
        return Fixture(manager: manager, directory: directory)
    }
}

/// The fake native operation shares only lock-protected counters across worker/main threads.
/// Semaphores deliberately block the worker; production serialization remains NativeLlamaSession's.
nonisolated private final class MaintenanceProbe: @unchecked Sendable {
    struct State {
        var calls = 0
        var finished = 0
        var concurrent = 0
        var maximumConcurrent = 0
        var onMainThread = false
    }
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var state = State()
    var snapshot: State { lock.withLock { state } }

    func run() {
        lock.withLock {
            state.calls += 1; state.concurrent += 1
            state.maximumConcurrent = max(state.maximumConcurrent, state.concurrent)
            state.onMainThread = state.onMainThread || Thread.isMainThread
        }
        started.signal()
        _ = resume.wait(timeout: .now() + 2)
        lock.withLock { state.concurrent -= 1; state.finished += 1 }
    }
}
