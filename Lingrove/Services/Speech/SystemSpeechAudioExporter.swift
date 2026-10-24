import AVFoundation
import Foundation

/// The shared speech controller lazily owns one silent synthesizer. Apple may deliver an entire
/// offline utterance before an async consumer can run, so callback storage is byte-bounded rather
/// than a small dropping stream. No output device, temporary file or extra model runtime is used.
@MainActor
final class SystemSpeechAudioExporter {
    private let synthesizer = AVSpeechSynthesizer()
    func audio(text: String, voiceID: String) async throws -> SpeechExportAudio {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { throw SpeechError.unsupportedLanguage }
        let sink = SystemSpeechExportSink()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        defer { synthesizer.stopSpeaking(at: .immediate) }
        let recording = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard sink.install(continuation) else { return }
                synthesizer.write(utterance) { sink.receive($0) }
            }
        } onCancel: { sink.cancel() }
        try Task.checkCancellation()
        return try await SpeechExportBuffer().package(recording)
    }
}

/// A request-owned value leaves the callback only after its last buffer. It contains no mutable
/// AVFoundation object; the export actor packages these owned Float32 bytes as portable PCM16.
nonisolated struct SystemSpeechRecording: Sendable {
    let bytes: Data
    let sampleRate: Int
}

/// AVSpeech's callback and Swift cancellation can race on different threads. This narrow SDK
/// bridge locks only owned bytes and the one continuation, never calls the synthesizer under its
/// lock, and resumes after unlocking. Late callbacks belong to this retired sink, not a new export.
nonisolated private final class SystemSpeechExportSink: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var sampleRate: Int?
    private var finished = false
    private var waiter: CheckedContinuation<SystemSpeechRecording, Error>?

    func install(_ continuation: CheckedContinuation<SystemSpeechRecording, Error>) -> Bool {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
        waiter = continuation
        lock.unlock()
        return true
    }
    func cancel() { finish(error: CancellationError()) }
    func receive(_ buffer: AVAudioBuffer) {
        lock.lock(); let retired = finished; lock.unlock()
        guard !retired else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { finish(error: SpeechError.invalidAudio); return }
        if pcm.frameLength == 0 { finish(error: nil); return }
        do {
            let chunk = try Self.copy(pcm)
            lock.lock()
            guard !finished else { lock.unlock(); return }
            let valid = (sampleRate == nil || sampleRate == chunk.sampleRate) &&
                bytes.count + chunk.data.count <= SpeechExportPolicy.maximumBytes - 44 &&
                (bytes.count + chunk.data.count) / 4 <= chunk.sampleRate * 90
            if valid { sampleRate = chunk.sampleRate; bytes.append(chunk.data) }
            lock.unlock()
            if !valid { finish(error: SpeechError.responseTooLarge) }
        } catch { finish(error: error) }
    }
    private func finish(error: (any Error)?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = waiter
        let recording = sampleRate.map { SystemSpeechRecording(bytes: bytes, sampleRate: $0) }
        waiter = nil; bytes = Data()
        lock.unlock()
        if let error { continuation?.resume(throwing: error) } else if let recording {
            continuation?.resume(returning: recording)
        } else { continuation?.resume(throwing: SpeechError.invalidAudio) }
    }
    private static func copy(_ pcm: AVAudioPCMBuffer) throws -> SpeechPCMChunk {
        let frames = Int(pcm.frameLength), channels = Int(pcm.format.channelCount)
        guard channels > 0, channels <= 2, channels == 1 || !pcm.format.isInterleaved,
              frames * 4 <= SpeechPCMChunk.maximumBytes, let values = pcm.floatChannelData else {
            throw SpeechError.invalidAudio
        }
        var bytes = Data(capacity: frames * 4)
        for frame in 0..<frames {
            var sample: Float = 0
            for channel in 0..<channels { sample += values[channel][frame] / Float(channels) }
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return try SpeechPCMChunk(data: bytes, sampleRate: Int(pcm.format.sampleRate))
    }
}
