import Foundation

public struct WorkspaceTagSummary: Codable, Hashable, Sendable {
    public let tag: String
    public let cardsCount: Int

    public init(tag: String, cardsCount: Int) {
        self.tag = tag
        self.cardsCount = cardsCount
    }
}

public struct WorkspaceTagsSummary: Codable, Hashable, Sendable {
    public let tags: [WorkspaceTagSummary]
    public let totalCards: Int

    public init(tags: [WorkspaceTagSummary], totalCards: Int) {
        self.tags = tags
        self.totalCards = totalCards
    }
}

public struct StoredCardTag: Hashable, Sendable {
    public let cardId: String
    public let tag: String

    public init(cardId: String, tag: String) {
        self.cardId = cardId
        self.tag = tag
    }
}

public enum TagSuggestionCount: Hashable, Sendable {
    case loading
    case ready(cardsCount: Int)

    public var cardsCount: Int? {
        switch self {
        case .loading:
            return nil
        case .ready(let cardsCount):
            return cardsCount
        }
    }
}

public struct TagSuggestion: Hashable, Sendable {
    public let tag: String
    public let countState: TagSuggestionCount

    public init(tag: String, countState: TagSuggestionCount) {
        self.tag = tag
        self.countState = countState
    }
}
