import Foundation

/// The generator delivers ordered chunks to this request-owned accumulator. Keeping mutable
/// bytes in an actor lets the same receiver work for native callbacks and endpoint tasks.
actor SpeechExportBuffer {
    private var data = Data()
    private var sampleRate: Int?
    private var encoded: SpeechExportAudio?
    func append(_ chunk: SpeechAudioChunk) throws {
        try Task.checkCancellation()
        switch chunk {
        case .encoded(let bytes):
            guard data.isEmpty, encoded == nil else { throw SpeechError.invalidAudio }
            encoded = try SpeechExportPolicy.encoded(bytes)
        case .pcm(let pcm):
            guard encoded == nil, sampleRate == nil || sampleRate == pcm.sampleRate,
                  data.count + pcm.data.count <= SpeechExportPolicy.maximumBytes - 44 else { throw SpeechError.responseTooLarge }
            sampleRate = pcm.sampleRate; data.append(pcm.data)
        }
    }
    func package(_ recording: SystemSpeechRecording) throws -> SpeechExportAudio {
        try Task.checkCancellation()
        return try SpeechExportPolicy.wav(recording.bytes, sampleRate: recording.sampleRate)
    }
    func finish() throws -> SpeechExportAudio {
        if let encoded { return encoded }
        guard let sampleRate else { throw SpeechError.invalidAudio }
        return try SpeechExportPolicy.wav(data, sampleRate: sampleRate)
    }
}
