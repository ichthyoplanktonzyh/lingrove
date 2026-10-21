import Foundation

/// A single click or batch freezes its destination before any write. Credentials stay ephemeral;
/// every subsequent single-sense transaction must use this scope rather than rereading a newly
/// selected profile/model partway through the queue.
nonisolated struct ReviewOperationScope: Equatable, Sendable {
    let connection: AnkiConnection
    let profile: String
    let model: String
    let mapping: [ReviewField: String]
    let speechID: String?
    let defaultDeck: String
    let hadSavedDeck: Bool
    let defaultRecognition: Bool
    let defaultGap: Bool
}
