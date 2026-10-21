import CryptoKit
import Foundation

/// Export normalizes WAV to ordinary 16-bit PCM for Anki clients. Internal native Float32 PCM
/// stays unchanged. Filenames are content hashes, never words, paths or credentials; all work
/// happens in memory on the export buffer actor rather than the UI/audio render thread.
nonisolated enum SpeechExportPolicy {
    static let maximumBytes = 12 * 1_024 * 1_024
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func filename(_ audio: SpeechExportAudio) -> String { "lingrove-" + digest(audio.data) + "." + audio.fileExtension }
    static func validFilename(_ value: String) -> Bool {
        value.range(of: "^lingrove-[a-f0-9]{64}\\.(wav|mp3)$", options: .regularExpression) != nil
    }
    static func wav(_ bytes: Data, sampleRate: Int) throws -> SpeechExportAudio {
        guard !bytes.isEmpty, bytes.count <= maximumBytes - 44, bytes.count.isMultiple(of: 4),
              (8_000...192_000).contains(sampleRate), bytes.count / 4 <= sampleRate * 90 else { throw SpeechError.invalidAudio }
        var pcm = Data(capacity: bytes.count / 2)
        try bytes.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let sample = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                guard sample.isFinite else { throw SpeechError.invalidAudio }
                var value = Int16((min(1, max(-1, sample)) * 32767).rounded()).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
        }
        return waveContainer(pcm, sampleRate: sampleRate, channels: 1)
    }
    private static func waveContainer(_ pcm: Data, sampleRate: Int, channels: Int) -> SpeechExportAudio {
        var data = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        number(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8))
        number(UInt32(16)); number(UInt16(1)); number(UInt16(channels))
        number(UInt32(sampleRate)); number(UInt32(sampleRate * channels * 2)); number(UInt16(channels * 2)); number(UInt16(16))
        data.append(Data("data".utf8)); number(UInt32(pcm.count)); data.append(pcm)
        return .init(data: data, fileExtension: "wav")
    }
    static func encoded(_ data: Data) throws -> SpeechExportAudio {
        guard !data.isEmpty, data.count <= maximumBytes else { throw SpeechError.responseTooLarge }
        if data.starts(with: Data("RIFF".utf8)), data.count >= 44, data[8..<12] == Data("WAVE".utf8) {
            return try normalizeWave(data)
        }
        if data.starts(with: Data("ID3".utf8)) || data.count > 2 && data[0] == 0xff &&
            data[1] & 0xe0 == 0xe0 && data[1] & 0x06 != 0 && data[1] & 0x18 != 0x08 {
            return .init(data: data, fileExtension: "mp3")
        }
        throw SpeechError.invalidAudio
    }
    /// Only the bounded RIFF metadata needed to preserve sample timing crosses parsing steps.
    private struct WaveFormat { let tag: Int; let channels: Int; let rate: Int; let bits: Int }

    private static func normalizeWave(_ data: Data) throws -> SpeechExportAudio {
        func number(_ at: Int, bytes: Int) -> Int {
            (0..<bytes).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) }
        }
        var offset = 12, format: WaveFormat?, samples: Data?
        while offset + 8 <= data.count {
            let size = number(offset + 4, bytes: 4), start = offset + 8
            guard size <= data.count - start else { throw SpeechError.invalidAudio }
            let name = String(data: data[offset..<offset + 4], encoding: .ascii)
            if name == "fmt ", size >= 16 {
                format = .init(tag: number(start, bytes: 2), channels: number(start + 2, bytes: 2),
                    rate: number(start + 4, bytes: 4), bits: number(start + 14, bytes: 2))
            }
            if name == "data" { samples = data.subdata(in: start..<start + size) }
            offset = start + size + size % 2
        }
        guard let format, let samples, !samples.isEmpty, (1...2).contains(format.channels),
              (8_000...192_000).contains(format.rate) else { throw SpeechError.invalidAudio }
        if format.tag == 1, format.bits == 16, samples.count.isMultiple(of: format.channels * 2),
           samples.count / (format.channels * 2) <= format.rate * 90 {
            return waveContainer(samples, sampleRate: format.rate, channels: format.channels)
        }
        if format.tag == 3, format.bits == 32, format.channels == 1 { return try wav(samples, sampleRate: format.rate) }
        throw SpeechError.invalidAudio
    }
}
