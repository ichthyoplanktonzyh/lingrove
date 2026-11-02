import Foundation

public let allCardsDeckLabel: String = String(
    localized: "cards.all_cards_deck_label",
    table: "Foundation",
    comment: "System deck label for all cards"
)

// Keep raw values in sync with apps/backend/src/scheduling/index.ts::ReviewRating,
// apps/web/src/types.ts review rating wire fields, and
// apps/android/data/local/src/main/java/com/flashcardsopensourceapp/data/local/model/review/ReviewModels.kt::ReviewRating.
public enum ReviewRating: Int, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case again = 0
    case hard = 1
    case good = 2
    case easy = 3

    public var id: Int {
        rawValue
    }

    public var title: String {
        switch self {
        case .again:
            return String(
                localized: "review_rating.again.title",
                table: "Foundation",
                comment: "Review rating title for Again"
            )
        case .hard:
            return String(
                localized: "review_rating.hard.title",
                table: "Foundation",
                comment: "Review rating title for Hard"
            )
        case .good:
            return String(
                localized: "review_rating.good.title",
                table: "Foundation",
                comment: "Review rating title for Good"
            )
        case .easy:
            return String(
                localized: "review_rating.easy.title",
                table: "Foundation",
                comment: "Review rating title for Easy"
            )
        }
    }

    public var symbolName: String {
        switch self {
        case .again:
            return "arrow.uturn.backward.circle.fill"
        case .hard:
            return "tortoise.circle.fill"
        case .good:
            return "checkmark.circle.fill"
        case .easy:
            return "sparkles"
        }
    }
}

public enum ReviewFilter: Hashable, Identifiable, Sendable {
    case allCards
    case deck(deckId: String)
    case tags(tags: [String])

    public var id: String {
        switch self {
        case .allCards:
            return "system-all-cards"
        case .deck(let deckId):
            return "deck:\(deckId)"
        case .tags(let tags):
            return "tags:\(tags.map(normalizeTagKey).joined(separator: "\u{1F}"))"
        }
    }
}

public func normalizedReviewTagNames(tags: [String]) -> [String] {
    normalizeTags(values: tags, referenceTags: []).sorted { leftTag, rightTag in
        let leftKey = normalizeTagKey(tag: leftTag)
        let rightKey = normalizeTagKey(tag: rightTag)
        if leftKey != rightKey {
            return leftKey < rightKey
        }

        return leftTag < rightTag
    }
}

public func makeReviewTagsFilter(tags: [String]) -> ReviewFilter {
    .tags(tags: normalizedReviewTagNames(tags: tags))
}

public func localizedReviewTagsFilterTitle(tags: [String]) -> String {
    switch tags.count {
    case 0:
        return String(localized: "No tags", table: "ReviewCards")
    case 1:
        return tags[0]
    default:
        let count = tags.count
        return String(
            localized: "\(count) tags",
            table: "ReviewCards",
            comment: "Review filter title for multiple selected tags"
        )
    }
}

extension ReviewFilter {
    public static func tag(tag: String) -> ReviewFilter {
        makeReviewTagsFilter(tags: [tag])
    }
}

public struct ReviewCounts: Hashable, Sendable {
    public let dueCount: Int
    public let totalCount: Int

    public init(dueCount: Int, totalCount: Int) {
        self.dueCount = dueCount
        self.totalCount = totalCount
    }
}

public enum ReviewQueryDefinition: Hashable, Sendable {
    case allCards
    case deck(filterDefinition: DeckFilterDefinition)
    case tag(exactTagNames: [String])
}

public struct ReviewTimelinePage: Hashable, Sendable {
    public let cards: [Card]
    public let hasMoreCards: Bool

    public init(cards: [Card], hasMoreCards: Bool) {
        self.cards = cards
        self.hasMoreCards = hasMoreCards
    }
}

public struct ReviewEvent: Codable, Identifiable, Hashable, Sendable {
    public let reviewEventId: String
    public let workspaceId: String
    public let cardId: String
    public let replicaId: String
    public let clientEventId: String
    public let rating: ReviewRating
    public let reviewedAtClient: String
    public let reviewedTimeZone: String?
    public let reviewedAtServer: String

    public enum CodingKeys: String, CodingKey {
        case reviewEventId
        case workspaceId
        case cardId
        case replicaId
        case clientEventId
        case rating
        case reviewedAtClient
        case reviewedTimeZone
        case reviewedAtServer
    }

    public var id: String {
        reviewEventId
    }

    public init(
        reviewEventId: String,
        workspaceId: String,
        cardId: String,
        replicaId: String,
        clientEventId: String,
        rating: ReviewRating,
        reviewedAtClient: String,
        reviewedTimeZone: String?,
        reviewedAtServer: String
    ) {
        self.reviewEventId = reviewEventId
        self.workspaceId = workspaceId
        self.cardId = cardId
        self.replicaId = replicaId
        self.clientEventId = clientEventId
        self.rating = rating
        self.reviewedAtClient = reviewedAtClient
        self.reviewedTimeZone = reviewedTimeZone
        self.reviewedAtServer = reviewedAtServer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reviewEventId = try container.decode(String.self, forKey: .reviewEventId)
        self.workspaceId = try container.decode(String.self, forKey: .workspaceId)
        self.cardId = try container.decode(String.self, forKey: .cardId)
        self.replicaId = try container.decode(String.self, forKey: .replicaId)
        self.clientEventId = try container.decode(String.self, forKey: .clientEventId)
        self.rating = try container.decode(ReviewRating.self, forKey: .rating)
        self.reviewedAtClient = try container.decode(String.self, forKey: .reviewedAtClient)
        self.reviewedTimeZone = try container.decodeIfPresent(String.self, forKey: .reviewedTimeZone)
        self.reviewedAtServer = try container.decode(String.self, forKey: .reviewedAtServer)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.reviewEventId, forKey: .reviewEventId)
        try container.encode(self.workspaceId, forKey: .workspaceId)
        try container.encode(self.cardId, forKey: .cardId)
        try container.encode(self.clientEventId, forKey: .clientEventId)
        try container.encode(self.rating, forKey: .rating)
        try container.encode(self.reviewedAtClient, forKey: .reviewedAtClient)
        try container.encodeIfPresent(self.reviewedTimeZone, forKey: .reviewedTimeZone)
        try container.encode(self.reviewedAtServer, forKey: .reviewedAtServer)
    }
}

public enum ReviewRefreshMode: Hashable, Sendable {
    case blockingReset
    case backgroundReconcileSilently
    case backgroundReconcileWithVisibleChangeBanner
}

public struct ReviewSubmission: Hashable, Sendable {
    public let cardId: String
    public let rating: ReviewRating
    public let reviewedAtClient: String
    public let reviewedTimeZone: String?

    public init(cardId: String, rating: ReviewRating, reviewedAtClient: String, reviewedTimeZone: String?) {
        self.cardId = cardId
        self.rating = rating
        self.reviewedAtClient = reviewedAtClient
        self.reviewedTimeZone = reviewedTimeZone
    }
}
