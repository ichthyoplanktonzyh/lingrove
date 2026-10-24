import Foundation

/// The app-owned controller injects this playback seam in tests. Callbacks always identify their
/// utterance; an old scheduled-buffer callback cannot retire a new player session.
@MainActor
protocol SpeechPCMPlaying: AnyObject {
    var eventHandler: (@MainActor @Sendable (SpeechProviderEvent) -> Void)? { get set }
    func begin(sampleRate: Int, rate: Double, token: SpeechPlaybackToken)
    func enqueue(_ chunk: SpeechPCMChunk, token: SpeechPlaybackToken) async throws
    func endInput(token: SpeechPlaybackToken) async throws
    func stop()
    func shutdown()
}

/// Owns per-utterance queue accounting and UI events; the audio actor owns device work. Preparing
/// starts on an explicit local speech request and overlaps model startup. The first PCM waits for
/// that same readiness task, so it cannot race graph setup or block the MainActor doing AV work.
@MainActor
final class SpeechPCMPlayer: SpeechPCMPlaying {
    var eventHandler: (@MainActor @Sendable (SpeechProviderEvent) -> Void)?
    private let renderer: any SpeechPCMRendering
    private var preparation: Task<Void, Error>?
    private var revision: UInt64 = 0
    private var token: SpeechPlaybackToken?
    private var rate = 1.0
    private var sampleRate: Int?
    private var state = SpeechPCMPlaybackState()
    private var playing = false
    private var drainWatchdog: Task<Void, Never>?

    init(renderer: any SpeechPCMRendering = SpeechPCMRenderer()) { self.renderer = renderer }

    func begin(sampleRate: Int, rate: Double, token: SpeechPlaybackToken) {
        stop()
        revision += 1
        let revision = revision
        self.rate = min(max(rate, 0.5), 1.5)
        self.sampleRate = sampleRate
        self.token = token
        let rate = self.rate
        preparation = Task { [weak self, renderer] in
            let start = ContinuousClock.now
            do {
                try await renderer.prepare(sampleRate: sampleRate, rate: rate, revision: revision,
                    played: { [weak self] id in await self?.played(id, token: token) },
                    invalidated: { [weak self] in await self?.failed(token) })
                try Task.checkCancellation()
                guard self?.token == token else { throw CancellationError() }
                let elapsed = start.duration(to: .now).components
                let milliseconds = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
                self?.eventHandler?(.prepared(token, milliseconds: milliseconds))
            } catch is CancellationError { throw CancellationError() } catch {
                self?.failed(token)
                throw error
            }
        }
    }

    func enqueue(_ chunk: SpeechPCMChunk, token: SpeechPlaybackToken) async throws {
        try requireActive(token)
        guard sampleRate == chunk.sampleRate else { throw SpeechError.invalidAudio }
        try await preparation?.value
        try requireActive(token)
        while Double(state.queuedSamples) / Double(chunk.sampleRate) / rate >= 2 {
            try await Task.sleep(for: .milliseconds(20))
            try requireActive(token)
        }
        let bufferID = try state.enqueue(samples: chunk.sampleCount)
        try await renderer.enqueue(chunk, bufferID: bufferID, revision: revision)
        try requireActive(token)
        try await startIfBuffered(token)
    }

    private func startIfBuffered(_ token: SpeechPlaybackToken) async throws {
        if !playing, let sampleRate, state.canStart(sampleRate: sampleRate, rate: rate) {
            try await renderer.play(revision: revision)
            try requireActive(token)
            playing = true
            eventHandler?(.started(token))
        }
    }

    func endInput(token: SpeechPlaybackToken) async throws {
        try requireActive(token)
        try state.endInput()
        try await startIfBuffered(token)
        finishIfDrained(token)
        guard self.token == token, let sampleRate else { return }
        let seconds = Double(state.queuedSamples) / Double(sampleRate) / rate + 5
        drainWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.failed(token)
        }
    }

    func stop() { retire(release: false) }
    func shutdown() { retire(release: true) }

    private func retire(release: Bool) {
        // Invalidate before stopping native playback: discarded buffers can finish synchronously.
        // A newer revision wins even if these unstructured stop/begin Tasks arrive out of order.
        token = nil
        revision += 1
        let revision = revision
        preparation?.cancel()
        preparation = nil
        drainWatchdog?.cancel()
        drainWatchdog = nil
        state = SpeechPCMPlaybackState()
        sampleRate = nil
        playing = false
        Task { [renderer] in await renderer.stop(revision: revision, release: release) }
    }

    private func requireActive(_ token: SpeechPlaybackToken) throws {
        try Task.checkCancellation()
        guard self.token == token else { throw CancellationError() }
    }

    private func played(_ bufferID: Int, token: SpeechPlaybackToken) {
        guard self.token == token else { return }
        state.played(bufferID)
        finishIfDrained(token)
    }

    private func finishIfDrained(_ token: SpeechPlaybackToken) {
        guard state.isFinished else { return }
        stop()
        eventHandler?(.finished(token))
    }

    private func failed(_ token: SpeechPlaybackToken) {
        guard self.token == token else { return }
        stop()
        eventHandler?(.failed(token, message: SpeechError.invalidAudio.localizedDescription))
    }
}
