import Foundation

private let maximumSearchTokenCount = 5
private let reviewCardsStringsTableName: String = "ReviewCards"

// Keep in sync with apps/backend/src/search/tokens.ts::tokenizeSearchText.
public func tokenizeSearchText(searchText: String) -> [String] {
    let normalizedSearchText = searchText
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    if normalizedSearchText.isEmpty {
        return []
    }

    let tokens = normalizedSearchText
        .split(whereSeparator: { character in
            character.isWhitespace
        })
        .map(String.init)
    if tokens.count <= maximumSearchTokenCount {
        return tokens
    }

    return Array(tokens.prefix(maximumSearchTokenCount - 1))
        + [tokens.dropFirst(maximumSearchTokenCount - 1).joined(separator: " ")]
}

public func matchesAnySearchToken(values: [String], searchTokens: [String]) -> Bool {
    let normalizedValues = values.map { value in
        value.lowercased()
    }

    return searchTokens.contains { token in
        normalizedValues.contains { value in
            value.contains(token)
        }
    }
}

public func matchesAllSearchTokens(values: [String], searchTokens: [String]) -> Bool {
    let normalizedValues = values.map { value in
        value.lowercased()
    }

    return searchTokens.allSatisfy { token in
        normalizedValues.contains { value in
            value.contains(token)
        }
    }
}

public func searchCards(cards: [Card], searchText: String) -> [Card] {
    let searchTokens = tokenizeSearchText(searchText: searchText)
    if searchTokens.isEmpty {
        return cards
    }

    return cards.filter { card in
        matchesAllSearchTokens(
            values: [card.frontText, card.backText] + card.tags,
            searchTokens: searchTokens
        )
    }
}

public func isCardDue(card: Card, now: Date, onInvalidDueAt: ((String, String) -> Void)? = nil) -> Bool {
    guard let dueAt = card.dueAt else {
        return true
    }

    guard let dueDate = parseIsoTimestamp(value: dueAt) else {
        onInvalidDueAt?(card.cardId, dueAt)
        return false
    }

    return dueDate <= now
}

public func isCardNew(card: Card) -> Bool {
    card.reps == 0 && card.lapses == 0
}

public func isCardReviewed(card: Card) -> Bool {
    card.reps > 0 || card.lapses > 0
}

public func matchesDeckFilterDefinition(filterDefinition: DeckFilterDefinition, card: Card) -> Bool {
    // Keep deck matching semantics aligned with apps/web/src/appData/domain/index.ts::matchesDeckFilterDefinition and apps/android/data/local/src/main/java/com/flashcardsopensourceapp/data/local/model/cards/FilterSupport.kt::matchesDeckFilterDefinition.
    if filterDefinition.tags.isEmpty {
        return true
    }

    let cardTagKeys = Set(card.tags.map { tag in
        normalizeTagKey(tag: tag)
    })
    return filterDefinition.tags.contains { tag in
        cardTagKeys.contains(normalizeTagKey(tag: tag))
    }
}

public func matchesCardFilter(filter: CardFilter, card: Card) -> Bool {
    if filter.tags.isEmpty {
        return true
    }

    let cardTagKeys = Set(card.tags.map { tag in
        normalizeTagKey(tag: tag)
    })
    return filter.tags.contains { tag in
        cardTagKeys.contains(normalizeTagKey(tag: tag))
    }
}

public func buildCardFilter(tags: [String], referenceTags: [String]) -> CardFilter? {
    let normalizedTags = normalizeTags(values: tags, referenceTags: referenceTags)
    if normalizedTags.isEmpty {
        return nil
    }

    return CardFilter(tags: normalizedTags)
}

public func cardFilterActiveDimensionCount(filter: CardFilter?) -> Int {
    guard let filter else {
        return 0
    }

    return filter.tags.isEmpty == false ? 1 : 0
}

public func localizedAllCardsLabel() -> String {
    String(localized: "All cards", table: reviewCardsStringsTableName)
}

public func localizedNoTagsLabel() -> String {
    String(localized: "No tags", table: reviewCardsStringsTableName)
}

public func formatCardFilterSummary(filter: CardFilter?) -> String {
    guard let filter else {
        return String(localized: "No filters", table: reviewCardsStringsTableName)
    }

    var parts: [String] = []
    if filter.tags.isEmpty == false {
        parts.append(
            String(
                format: String(localized: "Tags: %@", table: reviewCardsStringsTableName),
                locale: Locale.current,
                filter.tags.joined(separator: ", ")
            )
        )
    }

    if parts.isEmpty {
        return String(localized: "No filters", table: reviewCardsStringsTableName)
    }

    return ListFormatter.localizedString(byJoining: parts)
}

public func queryCards(cards: [Card], searchText: String, filter: CardFilter?) -> [Card] {
    let filteredCards: [Card]
    if let filter {
        filteredCards = cards.filter { card in
            matchesCardFilter(filter: filter, card: card)
        }
    } else {
        filteredCards = cards
    }

    return searchCards(cards: filteredCards, searchText: searchText)
}

public func buildDeckFilterDefinition(tags: [String]) -> DeckFilterDefinition {
    return DeckFilterDefinition(
        version: 2,
        tags: tags
    )
}

public func resolveDeckFilterDefinitionTagNames(
    filterDefinition: DeckFilterDefinition,
    storedTagNames: [String]
) -> DeckFilterDefinition {
    guard filterDefinition.tags.isEmpty == false else {
        return filterDefinition
    }

    let exactTagNames = resolveExactStoredTagNames(
        requestedTagNames: filterDefinition.tags,
        storedTagNames: storedTagNames
    )
    guard exactTagNames.isEmpty == false else {
        return filterDefinition
    }

    return DeckFilterDefinition(
        version: filterDefinition.version,
        tags: exactTagNames
    )
}

public func formatDeckFilterDefinition(filterDefinition: DeckFilterDefinition) -> String {
    var parts: [String] = []

    if filterDefinition.tags.isEmpty == false {
        parts.append("tags any of \(filterDefinition.tags.joined(separator: ", "))")
    }

    if parts.isEmpty {
        return localizedAllCardsLabel()
    }

    return parts.joined(separator: " AND ")
}

public func deriveActiveCards(cards: [Card]) -> [Card] {
    cards.filter { card in
        card.deletedAt == nil
    }
}

public func makeDeckCardStats(cards: [Card], now: Date, excludedReviewCardIds: Set<String> = []) -> DeckCardStats {
    DeckCardStats(
        totalCards: cards.count,
        dueCards: cards.filter { card in
            !excludedReviewCardIds.contains(card.cardId) && isCardDue(card: card, now: now)
        }.count,
        newCards: cards.filter { card in
            isCardNew(card: card)
        }.count,
        reviewedCards: cards.filter { card in
            isCardReviewed(card: card)
        }.count
    )
}

public func makeHomeSnapshot(cards: [Card], deckCount: Int, now: Date) -> HomeSnapshot {
    let activeCards = deriveActiveCards(cards: cards)

    return HomeSnapshot(
        deckCount: deckCount,
        totalCards: activeCards.count,
        dueCount: activeCards.filter { card in
            isCardDue(card: card, now: now)
        }.count,
        newCount: activeCards.filter { card in
            isCardNew(card: card)
        }.count,
        reviewedCount: activeCards.filter { card in
            isCardReviewed(card: card)
        }.count
    )
}

public func cardsMatchingDeck(deck: Deck, cards: [Card]) -> [Card] {
    deriveActiveCards(cards: cards).filter { card in
        matchesDeckFilterDefinition(filterDefinition: deck.filterDefinition, card: card)
    }
}

public func makeDeckListItem(deck: Deck, cards: [Card], now: Date, excludedReviewCardIds: Set<String> = []) -> DeckListItem {
    let stats = makeDeckCardStats(cards: cards, now: now, excludedReviewCardIds: excludedReviewCardIds)

    return DeckListItem(
        deck: deck,
        totalCards: stats.totalCards,
        dueCards: stats.dueCards,
        newCards: stats.newCards,
        reviewedCards: stats.reviewedCards
    )
}

public func makeDeckListItems(decks: [Deck], cards: [Card], now: Date, excludedReviewCardIds: Set<String> = []) -> [DeckListItem] {
    decks.map { deck in
        makeDeckListItem(
            deck: deck,
            cards: cardsMatchingDeck(deck: deck, cards: cards),
            now: now,
            excludedReviewCardIds: excludedReviewCardIds
        )
    }
}
