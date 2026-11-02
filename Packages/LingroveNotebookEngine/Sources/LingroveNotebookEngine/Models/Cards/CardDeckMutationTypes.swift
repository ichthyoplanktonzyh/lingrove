import Foundation

public struct CardEditorInput: Codable, Hashable, Sendable {
    public let frontText: String
    public let backText: String
    public let tags: [String]

    public init(frontText: String, backText: String, tags: [String]) {
        self.frontText = frontText
        self.backText = backText
        self.tags = tags
    }
}

public struct CardUpdateInput: Hashable, Sendable {
    public let cardId: String
    public let input: CardEditorInput

    public init(cardId: String, input: CardEditorInput) {
        self.cardId = cardId
        self.input = input
    }
}

public struct BulkDeleteCardsResult: Hashable, Sendable {
    public let deletedCardIds: [String]
    public let deletedCount: Int

    public init(deletedCardIds: [String], deletedCount: Int) {
        self.deletedCardIds = deletedCardIds
        self.deletedCount = deletedCount
    }
}

public struct DeckEditorInput: Hashable, Sendable {
    public let name: String
    public let filterDefinition: DeckFilterDefinition

    public init(name: String, filterDefinition: DeckFilterDefinition) {
        self.name = name
        self.filterDefinition = filterDefinition
    }
}

public struct DeckUpdateInput: Hashable, Sendable {
    public let deckId: String
    public let input: DeckEditorInput

    public init(deckId: String, input: DeckEditorInput) {
        self.deckId = deckId
        self.input = input
    }
}

public struct BulkDeleteDecksResult: Hashable, Sendable {
    public let deletedDeckIds: [String]
    public let deletedCount: Int

    public init(deletedDeckIds: [String], deletedCount: Int) {
        self.deletedDeckIds = deletedDeckIds
        self.deletedCount = deletedCount
    }
}
