import LingroveNotebook
import Foundation

/// A single click or batch freezes its destination before any write. Credentials stay ephemeral;
/// every subsequent single-sense transaction must use this scope rather than rereading a newly
/// selected profile/model partway through the queue.
nonisolated struct ReviewOperationScope: Equatable, Sendable {
    /// The same explicit send can await Anki and speech. Retain the notebook lifetime too;
    /// a reply from an old account must not bind a note in the newly visible library.
    var notebookScope: VocabularyOperationScope?
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
