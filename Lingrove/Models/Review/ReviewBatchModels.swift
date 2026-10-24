import Foundation

/// Queue state is presentation-only. Stable notebook IDs and durable Anki bindings remain the
/// authority; a row number or a generated meaning is never used to identify a review note.
nonisolated struct ReviewBatchItem: Identifiable {
    let id = UUID()
    let selection: VocabularySelection
    var cardID: UUID?
    var expression: String
    var meaning: String
    var status: Status = .ready
    var message: String?
    nonisolated enum Status {
        case ready, verifyAudio, sending, synced, attention, failed, cancelled, unavailable, skipped
        var label: String {
            switch self {
            case .verifyAudio: String(localized: "Verify audio", table: "Vocabulary")
            case .ready: String(localized: "Ready to send", table: "Vocabulary")
            case .sending: String(localized: "Sending…", table: "Vocabulary")
            case .synced: String(localized: "Synced", table: "Vocabulary")
            case .attention: String(localized: "Needs preparation", table: "Vocabulary")
            case .failed: String(localized: "Send failed", table: "Vocabulary")
            case .cancelled: String(localized: "Stopped", table: "Vocabulary")
            case .unavailable: String(localized: "No longer in the notebook", table: "Vocabulary")
            case .skipped: String(localized: "Merged into another selected sense", table: "Vocabulary")
            }
        }
    }
}
