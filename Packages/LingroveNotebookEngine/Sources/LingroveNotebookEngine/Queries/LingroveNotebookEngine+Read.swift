import Foundation

private func loadStoredTagNames(database: LingroveNotebookEngine, workspaceId: String) throws -> [String] {
    try database.cardStore.loadStoredTagNames(workspaceId: workspaceId)
}

extension LingroveNotebookEngine {
    public func loadBootstrapSnapshot() throws -> AppBootstrapSnapshot {
        let workspace = try self.workspaceSettingsStore.loadWorkspace()
        return AppBootstrapSnapshot(
            workspace: workspace,
            userSettings: try self.workspaceSettingsStore.loadUserSettings(),
            schedulerSettings: try self.workspaceSettingsStore.loadWorkspaceSchedulerSettings(workspaceId: workspace.workspaceId),
            cloudSettings: try self.workspaceSettingsStore.loadCloudSettings()
        )
    }

    public func loadCachedWorkspaces() throws -> [Workspace] {
        try self.workspaceSettingsStore.loadCachedWorkspaces()
    }



    public func loadActiveCards(workspaceId: String) throws -> [Card] {
        try self.cardStore.loadCards(workspaceId: workspaceId)
    }

    public func loadActiveCard(workspaceId: String, cardId: String) throws -> Card {
        try self.cardStore.loadCard(workspaceId: workspaceId, cardId: cardId)
    }

    public func loadActiveCardCount(workspaceId: String) throws -> Int {
        try self.cardStore.loadActiveCardCount(workspaceId: workspaceId)
    }

    public func loadReviewEventCount() throws -> Int {
        try self.core.scalarInt(sql: "SELECT COUNT(*) FROM review_events WHERE workspace_id IN (\(LingroveNotebookAccountStore.visibleWorkspaceSQL))", values: [])
    }

    public func hasReviewEvent(workspaceId: String, after date: Date) throws -> Bool {
        try self.core.scalarInt(
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM review_events
                WHERE workspace_id = ? AND reviewed_at_client > ?
            )
            """,
            values: [
                .text(workspaceId),
                .text(formatIsoTimestamp(date: date))
            ]
        ) == 1
    }

    public func hasReviewEvent(workspaceId: String, start: Date, end: Date) throws -> Bool {
        try self.core.scalarInt(
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM review_events
                WHERE workspace_id = ? AND reviewed_at_client >= ? AND reviewed_at_client < ?
            )
            """,
            values: [
                .text(workspaceId),
                .text(formatIsoTimestamp(date: start)),
                .text(formatIsoTimestamp(date: end))
            ]
        ) == 1
    }

    public func loadActiveDecks(workspaceId: String) throws -> [Deck] {
        try self.deckStore.loadDecks(workspaceId: workspaceId)
    }

    public func loadResolvedReviewQuery(
        workspaceId: String,
        reviewFilter: ReviewFilter
    ) throws -> ResolvedReviewQuery {
        switch reviewFilter {
        case .allCards:
            return ResolvedReviewQuery(
                reviewFilter: .allCards,
                queryDefinition: .allCards
            )
        case .deck(let deckId):
            guard let deck = try self.loadOptionalDeck(workspaceId: workspaceId, deckId: deckId) else {
                return ResolvedReviewQuery(
                    reviewFilter: .allCards,
                    queryDefinition: .allCards
                )
            }
            let storedTagNames: [String]
            if deck.filterDefinition.tags.isEmpty {
                storedTagNames = []
            } else {
                storedTagNames = try loadStoredTagNames(database: self, workspaceId: workspaceId)
            }

            return ResolvedReviewQuery(
                reviewFilter: .deck(deckId: deckId),
                queryDefinition: .deck(
                    filterDefinition: resolveDeckFilterDefinitionTagNames(
                        filterDefinition: deck.filterDefinition,
                        storedTagNames: storedTagNames
                    )
                )
            )
        case .tags(let tags):
            let storedTagNames = try loadStoredTagNames(database: self, workspaceId: workspaceId)
            return resolveTagsReviewQuery(
                requestedTags: tags,
                storedTagNames: storedTagNames
            )
        }
    }

    public func loadReviewCounts(
        workspaceId: String,
        reviewQueryDefinition: ReviewQueryDefinition,
        now: Date
    ) throws -> ReviewCounts {
        try self.cardStore.loadReviewCounts(
            workspaceId: workspaceId,
            reviewQueryDefinition: reviewQueryDefinition,
            now: now
        )
    }

    public func loadReviewTimelinePage(
        workspaceId: String,
        reviewQueryDefinition: ReviewQueryDefinition,
        now: Date,
        limit: Int,
        offset: Int
    ) throws -> ReviewTimelinePage {
        try self.cardStore.loadReviewTimelinePage(
            workspaceId: workspaceId,
            reviewQueryDefinition: reviewQueryDefinition,
            now: now,
            limit: limit,
            offset: offset
        )
    }

    public func loadReviewHead(
        workspaceId: String,
        resolvedReviewFilter: ReviewFilter,
        reviewQueryDefinition: ReviewQueryDefinition,
        now: Date,
        limit: Int
    ) throws -> ReviewHeadLoadState {
        try self.cardStore.loadReviewHead(
            workspaceId: workspaceId,
            resolvedReviewFilter: resolvedReviewFilter,
            reviewQueryDefinition: reviewQueryDefinition,
            now: now,
            limit: limit
        )
    }



    public func loadReviewQueueChunk(
        workspaceId: String,
        reviewQueryDefinition: ReviewQueryDefinition,
        now: Date,
        limit: Int,
        excludedCardIds: Set<String>
    ) throws -> ReviewQueueChunkLoadState {
        try self.cardStore.loadReviewQueueChunk(
            workspaceId: workspaceId,
            reviewQueryDefinition: reviewQueryDefinition,
            now: now,
            limit: limit,
            excludedCardIds: excludedCardIds
        )
    }

    public func loadReviewQueueWindow(
        workspaceId: String,
        reviewQueryDefinition: ReviewQueryDefinition,
        now: Date,
        limit: Int
    ) throws -> ReviewQueueWindowLoadState {
        try self.cardStore.loadReviewQueueWindow(
            workspaceId: workspaceId,
            reviewQueryDefinition: reviewQueryDefinition,
            now: now,
            limit: limit
        )
    }

    public func hasAppWideReviewEvent(start: Date, end: Date) throws -> Bool {
        try self.cardStore.hasAppWideReviewEvent(start: start, end: end)
    }

    public func hasAppWideReviewEvent(before: Date) throws -> Bool {
        try self.cardStore.hasAppWideReviewEvent(before: before)
    }

    public func loadAppWideReviewEventCount(start: Date, end: Date) throws -> Int {
        try self.cardStore.loadAppWideReviewEventCount(start: start, end: end)
    }

    public func loadAppWideReviewDayCount(timeZone: TimeZone, dayStartHour: Int) throws -> Int {
        try self.cardStore.loadAppWideReviewDayCount(timeZone: timeZone, dayStartHour: dayStartHour)
    }

    public func loadCardsListSnapshot(
        workspaceId: String,
        searchText: String,
        filter: CardFilter?
    ) throws -> CardsListSnapshot {
        try self.cardStore.loadCardsListSnapshot(
            workspaceId: workspaceId,
            searchText: searchText,
            filter: filter
        )
    }

    public func loadDecksListSnapshot(
        workspaceId: String,
        now: Date
    ) throws -> DecksListSnapshot {
        let decks = try self.deckStore.loadDecks(workspaceId: workspaceId)
        let allCardsStats = try self.cardStore.loadDeckCardStats(
            workspaceId: workspaceId,
            filterDefinition: DeckFilterDefinition(version: 2, tags: []),
            now: now
        )
        let hasDeckTagFilters = decks.contains { deck in
            deck.filterDefinition.tags.isEmpty == false
        }
        let storedTagNames: [String]
        if hasDeckTagFilters {
            storedTagNames = try loadStoredTagNames(database: self, workspaceId: workspaceId)
        } else {
            storedTagNames = []
        }
        let deckSummaries = try decks.map { deck in
            let filterDefinition = resolveDeckFilterDefinitionTagNames(
                filterDefinition: deck.filterDefinition,
                storedTagNames: storedTagNames
            )
            let stats = try self.cardStore.loadDeckCardStats(
                workspaceId: workspaceId,
                filterDefinition: filterDefinition,
                now: now
            )
            return DeckSummary(
                deckId: deck.deckId,
                name: deck.name,
                filterDefinition: deck.filterDefinition,
                createdAt: deck.createdAt,
                totalCards: stats.totalCards,
                dueCards: stats.dueCards,
                newCards: stats.newCards,
                reviewedCards: stats.reviewedCards
            )
        }

        return DecksListSnapshot(
            deckSummaries: deckSummaries,
            allCardsStats: allCardsStats
        )
    }

    public func loadDeck(workspaceId: String, deckId: String) throws -> Deck {
        try self.deckStore.loadDeck(workspaceId: workspaceId, deckId: deckId)
    }

    public func loadOptionalDeck(workspaceId: String, deckId: String) throws -> Deck? {
        let deck = try self.deckStore.loadOptionalDeckIncludingDeleted(workspaceId: workspaceId, deckId: deckId)
        guard let deck, deck.deletedAt == nil else {
            return nil
        }

        return deck
    }

    public func loadWorkspaceTagsSummary(workspaceId: String) throws -> WorkspaceTagsSummary {
        try self.cardStore.loadWorkspaceTagsSummary(workspaceId: workspaceId)
    }

    public func loadWorkspaceOverviewSnapshot(
        workspaceId: String,
        workspaceName: String,
        now: Date
    ) throws -> WorkspaceOverviewSnapshot {
        let deckCount = try self.deckStore.loadDecks(workspaceId: workspaceId).count
        return try self.cardStore.loadWorkspaceOverviewSnapshot(
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            deckCount: deckCount,
            now: now
        )
    }

    public func loadCardsMatchingDeck(
        workspaceId: String,
        filterDefinition: DeckFilterDefinition
    ) throws -> [Card] {
        let storedTagNames: [String]
        if filterDefinition.tags.isEmpty {
            storedTagNames = []
        } else {
            storedTagNames = try loadStoredTagNames(database: self, workspaceId: workspaceId)
        }
        let resolvedFilterDefinition = resolveDeckFilterDefinitionTagNames(
            filterDefinition: filterDefinition,
            storedTagNames: storedTagNames
        )
        return try self.cardStore.loadCardsMatchingDeck(
            workspaceId: workspaceId,
            filterDefinition: resolvedFilterDefinition
        )
    }


}
