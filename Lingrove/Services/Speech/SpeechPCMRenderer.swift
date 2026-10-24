import AVFoundation
import Foundation

/// Only values and callbacks cross the audio actor boundary; AVFoundation's mutable graph never
/// leaves it. The MainActor player supplies monotonically increasing revisions because Tasks
/// reaching an actor are not FIFO: an old queued stop must not pause a newer utterance.
nonisolated protocol SpeechPCMRendering: Sendable {
    func prepare(sampleRate: Int, rate: Double, revision: UInt64,
                 played: @escaping SpeechPCMPlayedCallback, invalidated: @escaping SpeechPCMInvalidationCallback) async throws
    func enqueue(_ chunk: SpeechPCMChunk, bufferID: Int, revision: UInt64) async throws
    func play(revision: UInt64) async throws
    func stop(revision: UInt64, release: Bool) async
}

/// One renderer belongs to the app's PCM player. It prepares the output device while the native
/// helper loads/generates, then reuses the graph across utterances. Pausing after drain or cancel
/// stops rendering during idle time without discarding the expensive output-device setup.
actor SpeechPCMRenderer: SpeechPCMRendering {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var speed: AVAudioUnitTimePitch?
    private var sampleRate: Int?
    private var revision: UInt64 = 0
    private var active = false
    private var played: SpeechPCMPlayedCallback?
    private var invalidated: SpeechPCMInvalidationCallback?
    private var graphID: UUID?
    private var configurationObserver: (any NSObjectProtocol)?

    func prepare(sampleRate: Int, rate: Double, revision: UInt64,
                 played: @escaping SpeechPCMPlayedCallback, invalidated: @escaping SpeechPCMInvalidationCallback) throws {
        try Task.checkCancellation()
        guard revision > self.revision else { throw CancellationError() }
        self.revision = revision
        active = false
        node?.stop()
        // prepare may overtake the facade's older stop Task. Retiring the previous graph's
        // hardware here as well ensures a reused engine cannot silently render during loading.
        engine?.pause()
        // TimePitch owns a processing window beyond the player's scheduled buffers. Clear its
        // latency/tail as well, so resuming a reused graph cannot leak the previous utterance.
        speed?.reset()
        self.played = played
        self.invalidated = invalidated
        do {
            if engine == nil || self.sampleRate != sampleRate {
                releaseGraph()
                try createGraph(sampleRate: sampleRate)
                engine?.prepare()
                try engine?.start()
                // The first start initializes the hardware while model loading runs in parallel.
                // Immediately pause: keep allocated resources, not a silent render loop, while
                // generation is still preparing. Resuming this graph at first playback is cheap.
                engine?.pause()
            }
            speed?.rate = Float(rate)
            guard let engine, !engine.isRunning else { throw SpeechError.invalidAudio }
            active = true
        } catch {
            releaseGraph()
            self.played = nil
            self.invalidated = nil
            throw error
        }
    }

    func enqueue(_ chunk: SpeechPCMChunk, bufferID: Int, revision: UInt64) throws {
        try requireActive(revision)
        guard sampleRate == chunk.sampleRate, let node,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(chunk.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.sampleCount)),
              let channel = buffer.floatChannelData?[0] else { throw SpeechError.invalidAudio }
        buffer.frameLength = buffer.frameCapacity
        // The validated Float32 block is copied into AVFoundation-owned storage. No node/buffer
        // reference crosses back to UI, and only the captured old callback can settle this buffer.
        chunk.data.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: chunk.data.count))
        let callback = played
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // Never stop/unschedule from inside AVFoundation's completion callback; that can
            // deadlock its render thread. The async callback settles accounting on MainActor.
            Task { await self?.bufferCompleted(bufferID, revision: revision, callback: callback) }
        }
    }

    func play(revision: UInt64) throws {
        try requireActive(revision)
        guard let engine else { throw SpeechError.invalidAudio }
        if !engine.isRunning { try engine.start() }
        node?.play()
    }

    func stop(revision: UInt64, release: Bool) {
        guard revision >= self.revision else { return }
        self.revision = revision
        active = false
        played = nil
        invalidated = nil
        node?.stop()
        engine?.pause()
        speed?.reset()
        if release { releaseGraph() }
    }

    private func createGraph(sampleRate: Int) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
            throw SpeechError.invalidAudio
        }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let speed = AVAudioUnitTimePitch()
        engine.attach(node)
        engine.attach(speed)
        engine.connect(node, to: speed, format: format)
        engine.connect(speed, to: engine.mainMixerNode, format: format)
        self.engine = engine
        self.node = node
        self.speed = speed
        self.sampleRate = sampleRate
        let id = UUID()
        graphID = id
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in Task { await self?.configurationChanged(id) } }
    }

    private func requireActive(_ revision: UInt64) throws {
        try Task.checkCancellation()
        guard revision == self.revision else { throw CancellationError() }
        // A device change invalidates the *current* request. Report a playback failure rather
        // than cancellation even if this call beats its notification's MainActor callback.
        guard active, engine != nil else { throw SpeechError.invalidAudio }
    }

    private func bufferCompleted(_ bufferID: Int, revision: UInt64, callback: SpeechPCMPlayedCallback?) async {
        // Device invalidation stops nodes before its failure can hop to MainActor. stop() can
        // complete discarded buffers too: reject them here, while the graph's invalidity is
        // already known, so an EOS queue cannot falsely finish ahead of the device failure.
        guard active, revision == self.revision else { return }
        await callback?(bufferID)
    }

    private func configurationChanged(_ id: UUID) async {
        guard graphID == id else { return }
        let callback = active ? invalidated : nil
        active = false
        played = nil
        invalidated = nil
        releaseGraph()
        await callback?()
    }

    private func releaseGraph() {
        // Retire the graph identity first: delayed notifications from an old device/engine are
        // harmless even when they reach this actor after the next graph has already been created.
        graphID = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        node?.stop()
        engine?.stop()
        node = nil
        speed = nil
        engine = nil
        sampleRate = nil
    }
}
