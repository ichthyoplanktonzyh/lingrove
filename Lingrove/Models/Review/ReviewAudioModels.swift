import LingroveNotebook
import Foundation

/// The two optional recordings belong to a review plan, independently of its source meaning.
typealias ReviewAudioKind = LingroveNotebook.ReviewAudioKind

/// A receipt names Anki-owned media and the exact text/voice settings that produced it. A
/// subsequent process can reuse a successful upload without persisting temporary audio locally.
typealias ReviewAudioReceipt = LingroveNotebook.ReviewAudioReceipt

/// A preparation sheet retains only its explicitly generated audio. Closing the sheet releases
/// the bytes; sending copies them to Anki. No WAV is written to the user's temporary directory.
nonisolated struct ReviewPreparedAudio: Sendable {
    let fingerprint: String
    let audio: SpeechExportAudio
}

/// The Mac host owns localized labels; shared review values carry stable field identities.
extension ReviewAudioKind {
    nonisolated var label: String { field.label }
}
