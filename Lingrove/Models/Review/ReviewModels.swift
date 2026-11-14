import LingroveNotebook
import Foundation

/// Configuration is snapshotted before every operation. The application only permits loopback
/// endpoints; an API key exists in memory/Keychain, never in the notebook or diagnostic fields.
nonisolated struct AnkiConnection: Sendable, Equatable {
    let endpoint: URL
    let apiKey: String
}

/// A connection probe returns only navigation metadata. The controller publishes this transient
/// snapshot; it is never treated as proof of the active profile during a later write.
nonisolated struct AnkiReviewCatalog: Equatable, Sendable {
    let profile: String
    let decks: [String]
    let models: [String]
}

/// One verified server read supplies conflict comparison and acknowledgement checks. Sessions
/// retain it only while preparing an explicit write, independently of the durable receipt.
nonisolated struct AnkiRemoteNote: Equatable, Sendable {
    let id: Int64
    let model: String
    let fields: [String: String]
}

/// Field-level conflict information belongs to a sheet session, not durable learning content.
/// A failed update leaves the original receipt intact until a verified write is acknowledged.
nonisolated struct AnkiFieldConflict: Identifiable, Equatable, Sendable {
    let id: String
    let local: String
    let remote: String
}

nonisolated enum AnkiReviewError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}
