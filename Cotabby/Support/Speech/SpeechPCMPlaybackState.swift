import Foundation

/// Pure queue accounting separates generation completion from audible playback completion.
/// A producer can finish before AVFoundation drains, or a slow producer can leave the queue empty
/// between blocks. Neither condition alone completes the user's utterance.
nonisolated struct SpeechPCMPlaybackState {
    private(set) var queuedSamples = 0
    private(set) var totalSamples = 0
    private(set) var inputEnded = false
    private var buffers: [Int: Int] = [:]
    private var nextID = 0

    mutating func enqueue(samples: Int) throws -> Int {
        guard !inputEnded, samples > 0, totalSamples <= 11_520_000 - samples else { throw SpeechError.invalidAudio }
        let id = nextID
        nextID += 1
        buffers[id] = samples
        queuedSamples += samples
        totalSamples += samples
        return id
    }

    mutating func played(_ id: Int) {
        if let count = buffers.removeValue(forKey: id) { queuedSamples -= count }
    }

    mutating func endInput() throws {
        guard totalSamples > 0, !inputEnded else { throw SpeechError.invalidAudio }
        inputEnded = true
    }

    var isFinished: Bool { inputEnded && queuedSamples == 0 }

    func canStart(sampleRate: Int, rate: Double) -> Bool {
        guard queuedSamples > 0, sampleRate > 0, rate > 0 else { return false }
        // Half a second of audible audio absorbs normal generation jitter at faster speeds.
        // EOS releases a short final utterance immediately instead of waiting for nonexistent data.
        return inputEnded || Double(queuedSamples) / Double(sampleRate) / rate >= 0.5
    }
}
