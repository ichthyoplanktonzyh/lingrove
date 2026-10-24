import Foundation
import Testing
@testable import Lingrove

/// Deliberately holds preparation past a cancellation to reproduce a native device call that
/// cannot be interrupted. The facade must remain responsive and reject its late completion.
@Suite @MainActor struct SpeechPCMPlayerTests {
    @Test func preparesBeforeAudioAndFirstBlockAwaitsTheSameBarrier() async throws {
        let renderer = GatedPCMRenderer()
        let player = SpeechPCMPlayer(renderer: renderer)
        defer { player.shutdown() }
        var events: [SpeechProviderEvent] = []
        player.eventHandler = { events.append($0) }
        let token = SpeechPlaybackToken()
        player.begin(sampleRate: 24_000, rate: 1, token: token)
        try await wait { await renderer.preparations.count == 1 }
        var entered = false
        let enqueue = Task { entered = true; try await player.enqueue(Self.chunk(), token: token) }
        try await wait { entered }
        #expect(await renderer.enqueues.isEmpty)
        #expect(events.isEmpty)
        await renderer.releasePreparation(at: 0)
        try await enqueue.value
        #expect(await renderer.preparations.count == 1)
        #expect(await renderer.enqueues.count == 1)
        #expect(events.contains(.started(token)))
        try await player.endInput(token: token)
        #expect(!events.contains(.finished(token)))
        await renderer.finishBuffer(preparation: 0, bufferID: 0)
        try await wait { events.contains(.finished(token)) }
    }

    @Test func cancelledPreparationAndOldDeviceNotificationCannotRetireNewPlayback() async throws {
        let renderer = GatedPCMRenderer()
        let player = SpeechPCMPlayer(renderer: renderer)
        defer { player.shutdown() }
        var events: [SpeechProviderEvent] = []
        player.eventHandler = { events.append($0) }
        let old = SpeechPlaybackToken()
        player.begin(sampleRate: 24_000, rate: 1, token: old)
        try await wait { await renderer.preparations.count == 1 }
        var entered = false
        let blocked = Task { entered = true; try await player.enqueue(Self.chunk(), token: old) }
        try await wait { entered }
        player.stop()
        let current = SpeechPlaybackToken()
        player.begin(sampleRate: 24_000, rate: 1.5, token: current)
        try await wait { await renderer.preparations.count == 2 }
        await renderer.releasePreparation(at: 1)
        try await player.enqueue(Self.chunk(), token: current)
        try await player.endInput(token: current)
        await renderer.releasePreparation(at: 0)
        await #expect(throws: CancellationError.self) { try await blocked.value }
        await renderer.invalidate(preparation: 0)
        #expect(!events.contains(.started(old)))
        #expect(!events.contains(.finished(current)))
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        #expect(await renderer.enqueues.count == 1)
        await renderer.finishBuffer(preparation: 1, bufferID: 0)
        try await wait { events.contains(.finished(current)) }
    }

    @Test func discardedScheduledBufferCannotDrainTheNextUtterancesMatchingBufferID() async throws {
        let renderer = GatedPCMRenderer()
        let player = SpeechPCMPlayer(renderer: renderer)
        defer { player.shutdown() }
        var events: [SpeechProviderEvent] = []
        player.eventHandler = { events.append($0) }
        let old = SpeechPlaybackToken(), current = SpeechPlaybackToken()
        player.begin(sampleRate: 24_000, rate: 1, token: old)
        try await wait { await renderer.preparations.count == 1 }
        await renderer.releasePreparation(at: 0)
        try await player.enqueue(Self.chunk(), token: old)
        player.stop()
        player.begin(sampleRate: 24_000, rate: 1, token: current)
        try await wait { await renderer.preparations.count == 2 }
        await renderer.releasePreparation(at: 1)
        try await player.enqueue(Self.chunk(), token: current)
        try await player.endInput(token: current)
        #expect(await renderer.enqueues.count == 2)
        await renderer.finishBuffer(preparation: 0, bufferID: 0)
        #expect(!events.contains(.finished(current)))
        await renderer.finishBuffer(preparation: 1, bufferID: 0)
        #expect(events.contains(.finished(current)))
    }

    @Test func currentDeviceInvalidationFailsOnceAndTheNextRequestCanRecover() async throws {
        let renderer = GatedPCMRenderer()
        let player = SpeechPCMPlayer(renderer: renderer)
        defer { player.shutdown() }
        var events: [SpeechProviderEvent] = []
        player.eventHandler = { events.append($0) }
        let first = SpeechPlaybackToken()
        player.begin(sampleRate: 24_000, rate: 1, token: first)
        try await wait { await renderer.preparations.count == 1 }
        await renderer.releasePreparation(at: 0)
        try await player.enqueue(Self.chunk(), token: first)
        await renderer.invalidate(preparation: 0)
        try await wait { events.contains { if case .failed(first, _) = $0 { true } else { false } } }
        await renderer.invalidate(preparation: 0)
        let next = SpeechPlaybackToken()
        player.begin(sampleRate: 24_000, rate: 1, token: next)
        try await wait { await renderer.preparations.count == 2 }
        await renderer.releasePreparation(at: 1)
        try await player.enqueue(Self.chunk(), token: next)
        #expect(events.contains(.started(next)))
        #expect(events.filter { if case .failed = $0 { true } else { false } }.count == 1)
    }

    @Test func preparationFailureIsReportedBeforeAnyModelAudioArrives() async throws {
        let renderer = GatedPCMRenderer()
        let player = SpeechPCMPlayer(renderer: renderer)
        defer { player.shutdown() }
        let token = SpeechPlaybackToken()
        var failed = false
        player.eventHandler = { if case .failed(token, _) = $0 { failed = true } }
        player.begin(sampleRate: 24_000, rate: 1, token: token)
        try await wait { await renderer.preparations.count == 1 }
        await renderer.failPreparation(at: 0)
        try await wait { failed }
        #expect(await renderer.enqueues.isEmpty)
        await #expect(throws: CancellationError.self) { try await player.enqueue(Self.chunk(), token: token) }
    }

    @Test func unexpectedSampleRateIsRejectedBeforeScheduling() async throws {
        let renderer = GatedPCMRenderer()
        let player = SpeechPCMPlayer(renderer: renderer)
        defer { player.shutdown() }
        let token = SpeechPlaybackToken()
        player.begin(sampleRate: 24_000, rate: 1, token: token)
        try await wait { await renderer.preparations.count == 1 }
        await renderer.releasePreparation(at: 0)
        let wrongFormat = try SpeechPCMChunk(data: Data(repeating: 0, count: 1_024), sampleRate: 48_000)
        await #expect(throws: SpeechError.self) { try await player.enqueue(wrongFormat, token: token) }
        #expect(await renderer.enqueues.isEmpty)
    }

    private static func chunk() throws -> SpeechPCMChunk {
        try .init(data: Data(repeating: 0, count: 76_800), sampleRate: 24_000)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PCMTestTimeout()
    }
}

private struct PCMTestTimeout: Error {}

private actor GatedPCMRenderer: SpeechPCMRendering {
    struct Preparation {
        let revision: UInt64
        let played: SpeechPCMPlayedCallback
        let invalidated: SpeechPCMInvalidationCallback
        let waiter: CheckedContinuation<Void, Error>
    }
    private(set) var preparations: [Preparation] = []
    private(set) var enqueues: [UInt64] = []

    func prepare(sampleRate: Int, rate: Double, revision: UInt64,
                 played: @escaping SpeechPCMPlayedCallback, invalidated: @escaping SpeechPCMInvalidationCallback) async throws {
        try await withCheckedThrowingContinuation { waiter in
            preparations.append(.init(revision: revision, played: played, invalidated: invalidated, waiter: waiter))
        }
    }
    func releasePreparation(at index: Int) { preparations[index].waiter.resume() }
    func failPreparation(at index: Int) { preparations[index].waiter.resume(throwing: SpeechError.invalidAudio) }
    func enqueue(_ chunk: SpeechPCMChunk, bufferID: Int, revision: UInt64) { enqueues.append(revision) }
    func play(revision: UInt64) {}
    func stop(revision: UInt64, release: Bool) {}
    func finishBuffer(preparation: Int, bufferID: Int) async { await preparations[preparation].played(bufferID) }
    func invalidate(preparation: Int) async { await preparations[preparation].invalidated() }
}
