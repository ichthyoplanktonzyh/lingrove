import Foundation

/// The two optional recordings belong to a review plan, independently of its source meaning.
nonisolated enum ReviewAudioKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case expression, sentence
    var id: String { rawValue }
    var field: ReviewField { self == .expression ? .expressionAudio : .sentenceAudio }
    var label: String { field.label }
}

/// A receipt names Anki-owned media and the exact text/voice settings that produced it. A
/// subsequent process can reuse a successful upload without persisting temporary audio locally.
nonisolated struct ReviewAudioReceipt: Codable, Equatable, Sendable {
    let fingerprint: String
    let textHash: String
    let endpoint: String
    let profile: String
    let filename: String
}

/// A preparation sheet retains only its explicitly generated audio. Closing the sheet releases
/// the bytes; sending copies them to Anki. No WAV is written to the user's temporary directory.
nonisolated struct ReviewPreparedAudio: Sendable {
    let fingerprint: String
    let audio: SpeechExportAudio
}
