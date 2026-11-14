import LingroveNotebook
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// An isolated stateful Anki implementation exercises the complete add/update/recovery protocol.
/// It simulates a committed write with a lost acknowledgement, which a stateless mock misses.
actor ReviewFakeAnki: AnkiConnecting {
    func perform(_ action: String, params: [String: AnkiValue], connection: AnkiConnection) async throws -> AnkiValue {
        switch action {
        case "getActiveProfile": return .string("Synthetic")
        case "deckNames": return .list(["Default", "Other"])
        case "modelNames": return .list([])
        case "guiDeckOverview": return .bool(true)
        default: throw AnkiReviewError.message("Unexpected connection fixture action: " + action)
        }
    }
}

@MainActor
final class ReviewFakeSpeechExporter: SpeechExporting {
    var exports = 0
    var delay: Duration = .zero
    var exportConfigurationID: String { "fixture" }
    func exportRequest(text: String, language: LearningLanguage?, context: String?) throws -> SpeechExportRequest {
        guard let language else { throw SpeechError.unrecognizedLanguage }
        return .init(text: text, language: language, fingerprint: SpeechExportPolicy.digest(Data(text.utf8)), source: .system(voiceID: "fixture"))
    }
    func exportAudio(_ request: SpeechExportRequest) async throws -> SpeechExportAudio {
        try Task.checkCancellation(); exports += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        var value = Float(exports) / 100
        let sample = withUnsafeBytes(of: &value) { Data($0) }
        let data = (0..<2400).reduce(into: Data()) { result, _ in result.append(sample) }
        return try SpeechExportPolicy.wav(data, sampleRate: 24_000)
    }
    func audition(_ audio: SpeechExportAudio, ownerID: UUID, language: LearningLanguage) throws {}
    func stop(ownerID: UUID) {}
}
