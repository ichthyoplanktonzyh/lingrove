import Foundation

/// An explicit Note send freezes repository lifetime, endpoint, profile and default deck.
/// Field mapping and model shape belong to its captured Note Type, never transport settings.
nonisolated struct ReviewOperationScope: Equatable, Sendable {
    var notebookScope: VocabularyOperationScope?
    let connection: AnkiConnection
    let profile: String
    let defaultDeck: String
}
