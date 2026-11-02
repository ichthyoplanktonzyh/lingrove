import Foundation

public struct HomeSnapshot: Codable, Hashable, Sendable {
    public let deckCount: Int
    public let totalCards: Int
    public let dueCount: Int
    public let newCount: Int
    public let reviewedCount: Int

    public init(deckCount: Int, totalCards: Int, dueCount: Int, newCount: Int, reviewedCount: Int) {
        self.deckCount = deckCount
        self.totalCards = totalCards
        self.dueCount = dueCount
        self.newCount = newCount
        self.reviewedCount = reviewedCount
    }
}

public struct CardsListSnapshot: Hashable, Sendable {
    public let cards: [Card]
    public let totalCount: Int

    public init(cards: [Card], totalCount: Int) {
        self.cards = cards
        self.totalCount = totalCount
    }
}

public struct DeckSummary: Identifiable, Hashable, Sendable {
    public let deckId: String
    public let name: String
    public let filterDefinition: DeckFilterDefinition
    public let createdAt: String
    public let totalCards: Int
    public let dueCards: Int
    public let newCards: Int
    public let reviewedCards: Int

    public var id: String {
        self.deckId
    }

    public init(deckId: String, name: String, filterDefinition: DeckFilterDefinition, createdAt: String, totalCards: Int, dueCards: Int, newCards: Int, reviewedCards: Int) {
        self.deckId = deckId
        self.name = name
        self.filterDefinition = filterDefinition
        self.createdAt = createdAt
        self.totalCards = totalCards
        self.dueCards = dueCards
        self.newCards = newCards
        self.reviewedCards = reviewedCards
    }
}

public struct DecksListSnapshot: Hashable, Sendable {
    public let deckSummaries: [DeckSummary]
    public let allCardsStats: DeckCardStats

    public init(deckSummaries: [DeckSummary], allCardsStats: DeckCardStats) {
        self.deckSummaries = deckSummaries
        self.allCardsStats = allCardsStats
    }
}

public struct WorkspaceOverviewSnapshot: Hashable, Sendable {
    public let workspaceName: String
    public let deckCount: Int
    public let tagsCount: Int
    public let totalCards: Int
    public let dueCount: Int
    public let newCount: Int
    public let reviewedCount: Int

    public init(workspaceName: String, deckCount: Int, tagsCount: Int, totalCards: Int, dueCount: Int, newCount: Int, reviewedCount: Int) {
        self.workspaceName = workspaceName
        self.deckCount = deckCount
        self.tagsCount = tagsCount
        self.totalCards = totalCards
        self.dueCount = dueCount
        self.newCount = newCount
        self.reviewedCount = reviewedCount
    }
}

public struct DeckListItem: Identifiable, Hashable, Sendable {
    public let deck: Deck
    public let totalCards: Int
    public let dueCards: Int
    public let newCards: Int
    public let reviewedCards: Int

    public var id: String {
        deck.deckId
    }

    public init(deck: Deck, totalCards: Int, dueCards: Int, newCards: Int, reviewedCards: Int) {
        self.deck = deck
        self.totalCards = totalCards
        self.dueCards = dueCards
        self.newCards = newCards
        self.reviewedCards = reviewedCards
    }
}

public struct DeckCardStats: Hashable, Sendable {
    public let totalCards: Int
    public let dueCards: Int
    public let newCards: Int
    public let reviewedCards: Int

    public init(totalCards: Int, dueCards: Int, newCards: Int, reviewedCards: Int) {
        self.totalCards = totalCards
        self.dueCards = dueCards
        self.newCards = newCards
        self.reviewedCards = reviewedCards
    }
}
