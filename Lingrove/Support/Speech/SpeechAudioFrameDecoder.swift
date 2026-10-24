import Foundation

/// The helper's stdout uses a length-prefixed JSON header followed by optional raw PCM bytes.
/// Keeping framing pure makes fragmented pipes, oversized headers and truncated output testable
/// without a process. The reader asks for one frame at a time so playback can apply backpressure.
nonisolated struct SpeechAudioFrameDecoder {
    struct Header: Decodable, Sendable {
        let event: String
        var protocolVersion: Int?
        var id: String?
        var sequence: Int?
        var sampleRate: Int?
        var samples: Int?
        var payloadBytes: Int?
        var ok: Bool?
        var format: String?
        var channels: Int?
    }
    struct Frame: Sendable {
        let header: Header
        let payload: Data
    }
    private var buffer = Data()

    mutating func append(_ data: Data) throws {
        guard data.count <= 16_384, buffer.count + data.count <= SpeechPCMChunk.maximumBytes + 20_484 else {
            throw SpeechError.invalidAudio
        }
        buffer.append(data)
    }

    mutating func next() throws -> Frame? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard (1...4_096).contains(length) else { throw SpeechError.invalidAudio }
        guard buffer.count >= 4 + length else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let header = try decoder.decode(Header.self, from: buffer.subdata(in: 4..<(4 + length)))
        let payloadBytes = header.payloadBytes ?? 0
        guard (0...SpeechPCMChunk.maximumBytes).contains(payloadBytes),
              header.event == "chunk" || payloadBytes == 0 else { throw SpeechError.invalidAudio }
        let end = 4 + length + payloadBytes
        guard buffer.count >= end else { return nil }
        let payload = buffer.subdata(in: (4 + length)..<end)
        buffer.removeSubrange(0..<end)
        return Frame(header: header, payload: payload)
    }

    func finish() throws {
        guard buffer.isEmpty else { throw SpeechError.invalidAudio }
    }
}
