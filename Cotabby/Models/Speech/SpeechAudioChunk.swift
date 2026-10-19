import Foundation

/// Named callback types keep the async isolation contract identical across the app and tests,
/// even when the targets use different Approachable Concurrency defaults.
typealias SpeechAudioReceiver = @Sendable (SpeechAudioChunk) async throws -> Void
typealias SpeechPCMReceiver = @Sendable (SpeechPCMChunk) async throws -> Void
typealias SpeechPCMPlayedCallback = @Sendable (Int) async -> Void
typealias SpeechPCMInvalidationCallback = @Sendable () async -> Void

/// Generation delivers either one encoded endpoint response or ordered local PCM blocks.
/// The controller owns playback; the runtime never owns an audio device or a SwiftUI view.
nonisolated enum SpeechAudioChunk: Sendable {
    case encoded(Data)
    case pcm(SpeechPCMChunk)
}

/// One mono Float32 little-endian block. Validation happens before crossing into AVFoundation;
/// a malformed helper cannot allocate an unbounded buffer or schedule non-finite samples.
nonisolated struct SpeechPCMChunk: Sendable, Equatable {
    static let maximumBytes = 262_144
    let data: Data
    let sampleRate: Int
    var sampleCount: Int { data.count / MemoryLayout<Float>.size }

    init(data: Data, sampleRate: Int) throws {
        guard (8_000...192_000).contains(sampleRate), !data.isEmpty,
              data.count <= Self.maximumBytes, data.count.isMultiple(of: 4) else { throw SpeechError.invalidAudio }
        let valid = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).allSatisfy { offset in
                let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let sample = Float(bitPattern: bits)
                return sample.isFinite && abs(sample) <= 8
            }
        }
        guard valid else { throw SpeechError.invalidAudio }
        self.data = data
        self.sampleRate = sampleRate
    }
}
