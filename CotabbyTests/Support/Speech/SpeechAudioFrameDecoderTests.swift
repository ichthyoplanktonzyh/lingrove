import Foundation
import Testing
@testable import Cotabby

struct SpeechAudioFrameDecoderTests {
    @Test func fragmentedPCMIsDeliveredOnceAndTruncationIsRejected() throws {
        let payload = Data(repeating: 0, count: 32)
        let frame = try wire(["event": "chunk", "payload_bytes": 32], payload: payload)
        var decoder = SpeechAudioFrameDecoder()
        for byte in frame.dropLast() {
            try decoder.append(Data([byte]))
            #expect(try decoder.next() == nil)
        }
        #expect(throws: (any Error).self) { try decoder.finish() }
        try decoder.append(Data(frame.suffix(1)))
        #expect(try decoder.next()?.payload == payload)
        #expect(try decoder.next() == nil)
        try decoder.finish()
    }

    @Test(arguments: [-1, 262_145, Int.max])
    func rejectsOversizedPayloadBeforeReadingIt(_ length: Int) throws {
        var decoder = SpeechAudioFrameDecoder()
        try decoder.append(wire(["event": "chunk", "payload_bytes": length]))
        #expect(throws: (any Error).self) { try decoder.next() }
    }

    @Test func rejectsInvalidHeaderAndNonPCMData() throws {
        var decoder = SpeechAudioFrameDecoder()
        try decoder.append(Data([0, 0, 16, 1]))
        #expect(throws: (any Error).self) { try decoder.next() }
        #expect(throws: (any Error).self) { try SpeechPCMChunk(data: Data([1]), sampleRate: 24_000) }
        var infinity = Float.infinity.bitPattern.littleEndian
        let bytes = withUnsafeBytes(of: &infinity) { Data($0) }
        #expect(throws: (any Error).self) { try SpeechPCMChunk(data: bytes, sampleRate: 24_000) }
    }

    @Test func coalescedFramesKeepTheirSeparateHeadersAndPayloads() throws {
        var data = try wire(["event": "ready", "protocol_version": 2])
        data.append(try wire(["event": "chunk", "payload_bytes": 16], payload: Data(repeating: 0, count: 16)))
        var decoder = SpeechAudioFrameDecoder()
        try decoder.append(data)
        #expect(try decoder.next()?.header.protocolVersion == 2)
        #expect(try decoder.next()?.payload.count == 16)
        #expect(try decoder.next() == nil)
        try decoder.finish()
    }

    private func wire(_ header: [String: Any], payload: Data = Data()) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: header)
        var length = UInt32(json.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(json)
        frame.append(payload)
        return frame
    }
}
