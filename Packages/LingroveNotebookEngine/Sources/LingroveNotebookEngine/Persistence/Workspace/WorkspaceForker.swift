import Foundation
import LingroveNotebook

private let workspaceForkReviewEventSelectBatchSize: Int = 500

private struct WorkspaceForkCardTextRow {
    let cardId: String
    let frontText: String
    let backText: String
}

private struct WorkspaceForkReviewEventRow {
    let sourceReviewEventId: String
    let sourceCardId: String
    let replicaId: String
    let clientEventId: String
    let rating: Int64
    let reviewedAtClient: String
    let reviewedTimeZone: String?
    let reviewedAtServer: String
}

public struct WorkspaceForker {
    public let core: DatabaseCore
    public let workspaceSettingsStore: WorkspaceSettingsStore
    public let shellStore: WorkspaceShellStore
    public let mediaTransferStore: MediaTransferStore
    public let outboxRewriter: WorkspaceOutboxRewriter

    /// Explicit notebook ownership confirmation reuses the established Card/
    /// media/review identity fork. It copies into the selected target without
    /// deleting either workspace or retargeting any original pending request.
    /// Already-merged guest Card content is skipped; held notebook exercises
    /// have never entered that legacy lane and remain held in their new scope.
    public func copyForNotebookOwnership(sourceWorkspaceID: String, targetWorkspaceID: String, notebookID: UUID, managedOnly: Bool) throws {
        let all = try loadWorkspaceForkIdMappings(sourceWorkspaceId: sourceWorkspaceID, destinationWorkspaceId: targetWorkspaceID)
        let held = try LingroveNotebookCardLinkStore(core: core).heldCardIds(workspaceId: sourceWorkspaceID)
        let cards = all.cardIdsBySourceId.filter { !managedOnly || held.contains($0.key) }
        var referencedAssets = try CardStore(core: core).loadCardsIncludingDeleted(workspaceId: sourceWorkspaceID)
            .filter { cards[$0.cardId] != nil }.reduce(into: Set<String>()) {
                $0.formUnion(managedMediaAssetIdsReferencedInMarkdown(text: $1.frontText))
                $0.formUnion(managedMediaAssetIdsReferencedInMarkdown(text: $1.backText))
            }
        // A manual face can hide generated media without relinquishing the recipe's ownership.
        // Carry the baseline and owned custom/audio resources too, so the next source refresh or
        // editor reopen in the new account still has its original material.
        for link in try LingroveNotebookCardLinkStore(core: core).load(workspaceId: sourceWorkspaceID, includingDeleted: true) where cards[link.cardId] != nil {
            if let generated = link.generatedContent {
                referencedAssets.formUnion(managedMediaAssetIdsReferencedInMarkdown(text: generated.frontText + "\n" + generated.backText))
            }
            if let plan = link.materialPlan {
                var references = Set(plan.audio.values.map(\.reference))
                references.formUnion(VocabularyContentPolicy.images(plan.layout.customContent).map(ReviewMaterialMediaReference.init(image:)))
                referencedAssets.formUnion(references.map { LingroveNotebookCardMaterial.mediaAssetID(reference: $0, workspaceID: sourceWorkspaceID) })
            }
        }
        guard referencedAssets.isSubset(of: Set(all.mediaAssetIdsBySourceId.keys)) else { throw LingroveNotebookAccountError.unavailableSource }
        let events = try CardStore(core: core).loadReviewEvents(workspaceId: sourceWorkspaceID)
        let eventIDs = Set(events.filter { cards[$0.cardId] != nil }.map(\.reviewEventId))
        let mappings = WorkspaceForkIdMappings(cardIdsBySourceId: cards, deckIdsBySourceId: managedOnly ? [:] : all.deckIdsBySourceId,
            mediaAssetIdsBySourceId: all.mediaAssetIdsBySourceId.filter { referencedAssets.contains($0.key) }, reviewEventIdsBySourceId: all.reviewEventIdsBySourceId.filter { eventIDs.contains($0.key) })
        try insertForkedCards(sourceWorkspaceId: sourceWorkspaceID, destinationWorkspaceId: targetWorkspaceID, forkMappings: mappings)
        // Guest legacy merge may already have installed the same deterministic
        // asset identities. Validate them before skipping duplicate registry rows.
        var newAssets: [String: String] = [:]
        for (source, target) in mappings.mediaAssetIdsBySourceId {
            if let existing = try MediaAssetStore(core: core).loadOptionalMediaAssetIncludingDeleted(workspaceId: targetWorkspaceID, mediaAssetId: target) {
                guard let original = try MediaAssetStore(core: core).loadOptionalMediaAssetIncludingDeleted(workspaceId: sourceWorkspaceID, mediaAssetId: source) else { throw LingroveNotebookAccountError.unavailableSource }
                guard existing.sha256 == original.sha256, existing.mimeType == original.mimeType, existing.sizeBytes == original.sizeBytes else {
                    throw LingroveNotebookAccountError.ownerMismatch
                }
            } else { newAssets[source] = target }
        }
        try insertForkedMediaAssets(sourceWorkspaceId: sourceWorkspaceID, destinationWorkspaceId: targetWorkspaceID,
            forkMappings: .init(cardIdsBySourceId: cards, deckIdsBySourceId: [:], mediaAssetIdsBySourceId: newAssets, reviewEventIdsBySourceId: [:]))
        try mediaTransferStore.copyForNotebookAccountOwnership(source: sourceWorkspaceID, target: targetWorkspaceID, assetIDs: mappings.mediaAssetIdsBySourceId)
        try rewriteForkedCardMediaAssetReferences(destinationWorkspaceId: targetWorkspaceID, forkMappings: mappings)
        try insertForkedDecks(sourceWorkspaceId: sourceWorkspaceID, destinationWorkspaceId: targetWorkspaceID, forkMappings: mappings)
        for (source, target) in cards {
            try core.execute(sql: "INSERT INTO card_tags(workspace_id,card_id,tag) SELECT ?,?,tag FROM card_tags WHERE workspace_id=? AND card_id=?",
                values: [.text(targetWorkspaceID), .text(target), .text(sourceWorkspaceID), .text(source)])
        }
        try insertForkedReviewEvents(sourceWorkspaceId: sourceWorkspaceID, destinationWorkspaceId: targetWorkspaceID, forkMappings: mappings)
        try LingroveNotebookAccountReviewHandoff(core: core).copyInTransaction(source: sourceWorkspaceID, target: targetWorkspaceID,
            notebookID: notebookID, cardIDs: cards, assetIDs: mappings.mediaAssetIdsBySourceId)
        try ReviewNoteStore(core: core).copyOwnership(source: sourceWorkspaceID, target: targetWorkspaceID, cardIDs: cards)
        let installation = try workspaceSettingsStore.loadCloudSettings().installationId
        let outbox = OutboxStore(core: core), cardStore = CardStore(core: core)
        let now = nowIsoTimestamp()
        for (_, target) in cards {
            let operation = UUID().uuidString.lowercased()
            try core.execute(sql: "UPDATE notebook_card_sync_holds SET creation_operation_id=? WHERE workspace_id=? AND card_id=?",
                values: [.text(operation), .text(targetWorkspaceID), .text(target)])
            try outbox.enqueueCardUpsertOperation(workspaceId: targetWorkspaceID, installationId: installation, operationId: operation,
                clientUpdatedAt: now, card: cardStore.loadCardIncludingDeleted(workspaceId: targetWorkspaceID, cardId: target),
                isInitialCreate: true, reviewScheduleImpact: true)
        }
        for (_, target) in mappings.deckIdsBySourceId {
            try outbox.enqueueDeckUpsertOperation(workspaceId: targetWorkspaceID, installationId: installation, operationId: UUID().uuidString.lowercased(),
                clientUpdatedAt: now, deck: DeckStore(core: core).loadDeckIncludingDeleted(workspaceId: targetWorkspaceID, deckId: target))
        }
        let copiedEvents = Set(mappings.reviewEventIdsBySourceId.values)
        for event in try cardStore.loadReviewEvents(workspaceId: targetWorkspaceID) where copiedEvents.contains(event.reviewEventId) {
            try outbox.enqueueReviewEventAppendOperation(workspaceId: targetWorkspaceID, installationId: installation,
                operationId: UUID().uuidString.lowercased(), clientUpdatedAt: now, reviewEvent: event)
        }
    }

    public func preserveLocalDataForEmptyRemoteWorkspace(
        sourceWorkspaceId: String,
        destinationWorkspaceId: String
    ) throws {
        let localWorkspace = try self.loadWorkspaceForLinking(sourceWorkspaceId: sourceWorkspaceId)
        let currentSettings: WorkspaceSchedulerSettings
        do {
            currentSettings = try self.workspaceSettingsStore.loadWorkspaceSchedulerSettings(workspaceId: sourceWorkspaceId)
        } catch {
            self.recordWorkspaceLinkReadFailure(
                failedRead: .loadWorkspaceSchedulerSettings,
                sourceWorkspaceId: sourceWorkspaceId
            )
            throw error
        }
        let forkMappings = try self.loadWorkspaceForkIdMappings(
            sourceWorkspaceId: sourceWorkspaceId,
            destinationWorkspaceId: destinationWorkspaceId
        )

        try self.shellStore.deleteWorkspaceIfExists(workspaceId: destinationWorkspaceId)
        try self.shellStore.insertWorkspaceFromLocalSettings(
            workspaceId: destinationWorkspaceId,
            name: localWorkspace.name,
            createdAt: localWorkspace.createdAt,
            settings: currentSettings
        )

        try self.insertForkedCards(
            sourceWorkspaceId: sourceWorkspaceId,
            destinationWorkspaceId: destinationWorkspaceId,
            forkMappings: forkMappings
        )
        try self.insertForkedMediaAssets(
            sourceWorkspaceId: sourceWorkspaceId,
            destinationWorkspaceId: destinationWorkspaceId,
            forkMappings: forkMappings
        )
        try self.rewriteForkedCardMediaAssetReferences(
            destinationWorkspaceId: destinationWorkspaceId,
            forkMappings: forkMappings
        )
        try self.mediaTransferStore.rewriteTransfersForWorkspaceFork(
            sourceWorkspaceId: sourceWorkspaceId,
            destinationWorkspaceId: destinationWorkspaceId,
            mediaAssetIdsBySourceId: forkMappings.mediaAssetIdsBySourceId
        )
        try self.insertForkedDecks(
            sourceWorkspaceId: sourceWorkspaceId,
            destinationWorkspaceId: destinationWorkspaceId,
            forkMappings: forkMappings
        )
        try self.insertForkedCardTags(
            sourceWorkspaceId: sourceWorkspaceId,
            destinationWorkspaceId: destinationWorkspaceId,
            forkMappings: forkMappings
        )
        try self.insertForkedReviewEvents(
            sourceWorkspaceId: sourceWorkspaceId,
            destinationWorkspaceId: destinationWorkspaceId,
            forkMappings: forkMappings
        )
        try self.outboxRewriter.rewriteOutboxForWorkspaceFork(
            sourceWorkspaceId: sourceWorkspaceId,
            destinationWorkspaceId: destinationWorkspaceId,
            forkMappings: forkMappings
        )

        try self.shellStore.updateAccountWorkspaceReference(workspaceId: destinationWorkspaceId)
        try self.shellStore.deleteWorkspaceIfExists(workspaceId: sourceWorkspaceId)
        try self.shellStore.resetSyncState(workspaceId: destinationWorkspaceId)
    }

    public func replaceLocalShellForNonEmptyRemoteWorkspace(
        sourceWorkspaceId: String,
        destinationWorkspaceId: String
    ) throws {
        let sourceWorkspace = try self.loadWorkspaceForLinking(sourceWorkspaceId: sourceWorkspaceId)
        try self.shellStore.deleteWorkspaceIfExists(workspaceId: destinationWorkspaceId)
        try self.shellStore.insertWorkspaceShell(
            workspace: CloudWorkspaceSummary(
                workspaceId: destinationWorkspaceId,
                name: sourceWorkspace.name,
                createdAt: sourceWorkspace.createdAt,
                isSelected: true
            )
        )
        try self.shellStore.resetSyncState(workspaceId: destinationWorkspaceId)
        try self.shellStore.updateAccountWorkspaceReference(workspaceId: destinationWorkspaceId)
        try self.shellStore.deleteWorkspaceIfExists(workspaceId: sourceWorkspaceId)
    }

    private func loadWorkspaceForLinking(sourceWorkspaceId: String) throws -> Workspace {
        do {
            return try self.workspaceSettingsStore.loadWorkspace()
        } catch {
            self.recordWorkspaceLinkReadFailure(failedRead: .loadWorkspace, sourceWorkspaceId: sourceWorkspaceId)
            throw error
        }
    }

    private func recordWorkspaceLinkReadFailure(failedRead: NotebookWorkspaceRead, sourceWorkspaceId: String) {
        var persistedActiveWorkspaceId: String?
        var workspaceRowCount: Int?
        var stateReadErrorType: String?
        do {
            // Read before the caller's transaction rolls back; diagnostics must never replace its error.
            let states = try self.core.query(
                sql: """
                SELECT
                    (SELECT active_workspace_id FROM app_local_settings WHERE settings_id = 1),
                    COUNT(*)
                FROM workspaces
                """,
                values: []
            ) { statement in
                (
                    activeWorkspaceId: DatabaseCore.columnOptionalText(statement: statement, index: 0),
                    workspaceRowCount: Int(DatabaseCore.columnInt64(statement: statement, index: 1))
                )
            }
            guard let state = states.first else {
                throw LocalStoreError.database("Workspace link diagnostics returned no state")
            }
            persistedActiveWorkspaceId = state.activeWorkspaceId
            workspaceRowCount = state.workspaceRowCount
        } catch {
            stateReadErrorType = String(reflecting: type(of: error))
        }
        core.diagnostics?(.workspaceReadFailed(read: failedRead, sourceWorkspaceID: sourceWorkspaceId,
            activeWorkspaceID: persistedActiveWorkspaceId, workspaceCount: workspaceRowCount, errorType: stateReadErrorType))
    }

    private func loadWorkspaceForkIdMappings(
        sourceWorkspaceId: String,
        destinationWorkspaceId: String
    ) throws -> WorkspaceForkIdMappings {
        let cardIds = try self.loadEntityIds(
            sql: "SELECT card_id FROM cards WHERE workspace_id = ? ORDER BY card_id ASC",
            workspaceId: sourceWorkspaceId
        )
        let deckIds = try self.loadEntityIds(
            sql: "SELECT deck_id FROM decks WHERE workspace_id = ? ORDER BY deck_id ASC",
            workspaceId: sourceWorkspaceId
        )
        let reviewEventIds = try self.loadEntityIds(
            sql: "SELECT review_event_id FROM review_events WHERE workspace_id = ? ORDER BY review_event_id ASC",
            workspaceId: sourceWorkspaceId
        )
        // Tombstoned media assets are mapped too so forked cards, forked
        // registry rows, and pending operations keep referencing one id space.
        let mediaAssetIds = try self.loadEntityIds(
            sql: "SELECT media_asset_id FROM media_assets WHERE workspace_id = ? ORDER BY media_asset_id ASC",
            workspaceId: sourceWorkspaceId
        )

        return WorkspaceForkIdMappings(
            cardIdsBySourceId: Dictionary(uniqueKeysWithValues: cardIds.map { cardId in
                (
                    cardId,
                    forkedCardIdForWorkspace(
                        sourceWorkspaceId: sourceWorkspaceId,
                        destinationWorkspaceId: destinationWorkspaceId,
                        sourceCardId: cardId
                    )
                )
            }),
            deckIdsBySourceId: Dictionary(uniqueKeysWithValues: deckIds.map { deckId in
                (
                    deckId,
                    forkedDeckIdForWorkspace(
                        sourceWorkspaceId: sourceWorkspaceId,
                        destinationWorkspaceId: destinationWorkspaceId,
                        sourceDeckId: deckId
                    )
                )
            }),
            mediaAssetIdsBySourceId: Dictionary(uniqueKeysWithValues: try mediaAssetIds.map { mediaAssetId in
                let destination: String
                if let prepared = try LingroveNotebookReviewMediaStore(core: core).media(assetID: mediaAssetId, workspaceID: sourceWorkspaceId) {
                    destination = LingroveNotebookCardMaterial.mediaAssetID(reference: prepared.reference, workspaceID: destinationWorkspaceId)
                } else {
                    destination = forkedMediaAssetIdForWorkspace(
                        sourceWorkspaceId: sourceWorkspaceId,
                        destinationWorkspaceId: destinationWorkspaceId,
                        sourceMediaAssetId: mediaAssetId
                    )
                }
                return (mediaAssetId, destination)
            }),
            reviewEventIdsBySourceId: Dictionary(uniqueKeysWithValues: reviewEventIds.map { reviewEventId in
                (
                    reviewEventId,
                    forkedReviewEventIdForWorkspace(
                        sourceWorkspaceId: sourceWorkspaceId,
                        destinationWorkspaceId: destinationWorkspaceId,
                        sourceReviewEventId: reviewEventId
                    )
                )
            })
        )
    }

    private func loadEntityIds(sql: String, workspaceId: String) throws -> [String] {
        try self.core.query(
            sql: sql,
            values: [.text(workspaceId)]
        ) { statement in
            DatabaseCore.columnText(statement: statement, index: 0)
        }
    }

    private func insertForkedCards(
        sourceWorkspaceId: String,
        destinationWorkspaceId: String,
        forkMappings: WorkspaceForkIdMappings
    ) throws {
        for (sourceCardId, destinationCardId) in forkMappings.cardIdsBySourceId {
            try self.core.execute(
                sql: """
                INSERT INTO cards (
                    card_id,
                    workspace_id,
                    front_text,
                    back_text,
                    card_type,
                    metadata_json,
                    tags_json,
                    due_at,
                    due_at_millis,
                    created_at,
                    reps,
                    lapses,
                    fsrs_card_state,
                    fsrs_step_index,
                    fsrs_stability,
                    fsrs_difficulty,
                    fsrs_last_reviewed_at,
                    fsrs_last_reviewed_at_millis,
                    fsrs_scheduled_days,
                    client_updated_at,
                    last_modified_by_replica_id,
                    last_operation_id,
                    updated_at,
                    deleted_at
                )
                SELECT
                    ?,
                    ?,
                    front_text,
                    back_text,
                    card_type,
                    metadata_json,
                    tags_json,
                    due_at,
                    due_at_millis,
                    created_at,
                    reps,
                    lapses,
                    fsrs_card_state,
                    fsrs_step_index,
                    fsrs_stability,
                    fsrs_difficulty,
                    fsrs_last_reviewed_at,
                    fsrs_last_reviewed_at_millis,
                    fsrs_scheduled_days,
                    client_updated_at,
                    last_modified_by_replica_id,
                    last_operation_id,
                    updated_at,
                    deleted_at
                FROM cards
                WHERE workspace_id = ? AND card_id = ?
                """,
                values: [
                    .text(destinationCardId),
                    .text(destinationWorkspaceId),
                    .text(sourceWorkspaceId),
                    .text(sourceCardId)
                ]
            )
        }
    }

    private func insertForkedDecks(
        sourceWorkspaceId: String,
        destinationWorkspaceId: String,
        forkMappings: WorkspaceForkIdMappings
    ) throws {
        for (sourceDeckId, destinationDeckId) in forkMappings.deckIdsBySourceId {
            try self.core.execute(
                sql: """
                INSERT INTO decks (
                    deck_id,
                    workspace_id,
                    name,
                    filter_definition_json,
                    created_at,
                    client_updated_at,
                    last_modified_by_replica_id,
                    last_operation_id,
                    updated_at,
                    deleted_at
                )
                SELECT
                    ?,
                    ?,
                    name,
                    filter_definition_json,
                    created_at,
                    client_updated_at,
                    last_modified_by_replica_id,
                    last_operation_id,
                    updated_at,
                    deleted_at
                FROM decks
                WHERE workspace_id = ? AND deck_id = ?
                """,
                values: [
                    .text(destinationDeckId),
                    .text(destinationWorkspaceId),
                    .text(sourceWorkspaceId),
                    .text(sourceDeckId)
                ]
            )
        }
    }

    private func insertForkedMediaAssets(
        sourceWorkspaceId: String,
        destinationWorkspaceId: String,
        forkMappings: WorkspaceForkIdMappings
    ) throws {
        for (sourceMediaAssetId, destinationMediaAssetId) in forkMappings.mediaAssetIdsBySourceId {
            try self.core.execute(
                sql: """
                INSERT INTO media_assets (
                    media_asset_id,
                    workspace_id,
                    mime_type,
                    size_bytes,
                    sha256,
                    source_url,
                    created_at,
                    client_updated_at,
                    last_modified_by_replica_id,
                    last_operation_id,
                    updated_at,
                    deleted_at
                )
                SELECT
                    ?,
                    ?,
                    mime_type,
                    size_bytes,
                    sha256,
                    source_url,
                    created_at,
                    client_updated_at,
                    last_modified_by_replica_id,
                    last_operation_id,
                    updated_at,
                    deleted_at
                FROM media_assets
                WHERE workspace_id = ? AND media_asset_id = ?
                """,
                values: [
                    .text(destinationMediaAssetId),
                    .text(destinationWorkspaceId),
                    .text(sourceWorkspaceId),
                    .text(sourceMediaAssetId)
                ]
            )
        }
    }

    /// Repoints `fcasset:` links in forked card text at the forked asset ids.
    ///
    /// Media bytes stay addressed by `sha256` in the workspace-independent blob
    /// cache, so only the registry ids inside the card bodies have to move.
    private func rewriteForkedCardMediaAssetReferences(
        destinationWorkspaceId: String,
        forkMappings: WorkspaceForkIdMappings
    ) throws {
        guard forkMappings.mediaAssetIdsBySourceId.isEmpty == false else {
            return
        }

        let cardTextRows: [WorkspaceForkCardTextRow] = try self.core.query(
            sql: """
            SELECT card_id, front_text, back_text
            FROM cards
            WHERE workspace_id = ? AND (front_text LIKE ? OR back_text LIKE ?)
            ORDER BY card_id ASC
            """,
            values: [
                .text(destinationWorkspaceId),
                .text("%\(managedMediaAssetReferenceSchemePrefix)%"),
                .text("%\(managedMediaAssetReferenceSchemePrefix)%")
            ]
        ) { statement in
            WorkspaceForkCardTextRow(
                cardId: DatabaseCore.columnText(statement: statement, index: 0),
                frontText: DatabaseCore.columnText(statement: statement, index: 1),
                backText: DatabaseCore.columnText(statement: statement, index: 2)
            )
        }

        for cardTextRow in cardTextRows {
            guard forkMappings.cardIdsBySourceId.values.contains(cardTextRow.cardId) else { continue }
            let frontText: String = markdownByRewritingManagedMediaAssetIds(
                text: cardTextRow.frontText,
                mediaAssetIdsBySourceId: forkMappings.mediaAssetIdsBySourceId
            )
            let backText: String = markdownByRewritingManagedMediaAssetIds(
                text: cardTextRow.backText,
                mediaAssetIdsBySourceId: forkMappings.mediaAssetIdsBySourceId
            )
            guard frontText != cardTextRow.frontText || backText != cardTextRow.backText else {
                continue
            }

            try self.core.execute(
                sql: """
                UPDATE cards
                SET front_text = ?, back_text = ?
                WHERE workspace_id = ? AND card_id = ?
                """,
                values: [
                    .text(frontText),
                    .text(backText),
                    .text(destinationWorkspaceId),
                    .text(cardTextRow.cardId)
                ]
            )
        }
    }

    private func insertForkedCardTags(
        sourceWorkspaceId: String,
        destinationWorkspaceId: String,
        forkMappings: WorkspaceForkIdMappings
    ) throws {
        let cardTags = try self.core.query(
            sql: """
            SELECT card_id, tag
            FROM card_tags
            WHERE workspace_id = ?
            ORDER BY card_id ASC, tag ASC
            """,
            values: [.text(sourceWorkspaceId)]
        ) { statement in
            (
                DatabaseCore.columnText(statement: statement, index: 0),
                DatabaseCore.columnText(statement: statement, index: 1)
            )
        }

        for (sourceCardId, tag) in cardTags {
            try self.core.execute(
                sql: """
                INSERT INTO card_tags (workspace_id, card_id, tag)
                VALUES (?, ?, ?)
                """,
                values: [
                    .text(destinationWorkspaceId),
                    .text(try forkMappings.cardIdsBySourceId.requireMappedId(entityType: "card", sourceId: sourceCardId)),
                    .text(tag)
                ]
            )
        }
    }

    private func insertForkedReviewEvents(
        sourceWorkspaceId: String,
        destinationWorkspaceId: String,
        forkMappings: WorkspaceForkIdMappings
    ) throws {
        let sourceReviewEventIds: [String] = forkMappings.reviewEventIdsBySourceId.keys.sorted()
        let sourceReviewEvents: [WorkspaceForkReviewEventRow] = try self.loadWorkspaceForkReviewEvents(
            sourceWorkspaceId: sourceWorkspaceId,
            sourceReviewEventIds: sourceReviewEventIds
        )

        for sourceReviewEvent in sourceReviewEvents {
            let destinationReviewEventId: String = try forkMappings.reviewEventIdsBySourceId.requireMappedId(
                entityType: "review_event",
                sourceId: sourceReviewEvent.sourceReviewEventId
            )
            let destinationCardId: String = try forkMappings.cardIdsBySourceId.requireMappedId(
                entityType: "card",
                sourceId: sourceReviewEvent.sourceCardId
            )
            try self.core.execute(
                sql: """
                INSERT INTO review_events (
                    review_event_id,
                    workspace_id,
                    card_id,
                    replica_id,
                    client_event_id,
                    rating,
                    reviewed_at_client,
                    reviewed_time_zone,
                    reviewed_at_server
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                values: [
                    .text(destinationReviewEventId),
                    .text(destinationWorkspaceId),
                    .text(destinationCardId),
                    .text(sourceReviewEvent.replicaId),
                    .text(sourceReviewEvent.clientEventId),
                    .integer(sourceReviewEvent.rating),
                    .text(sourceReviewEvent.reviewedAtClient),
                    sourceReviewEvent.reviewedTimeZone.map(SQLiteValue.text) ?? .null,
                    .text(sourceReviewEvent.reviewedAtServer)
                ]
            )
        }
    }

    private func loadWorkspaceForkReviewEvents(
        sourceWorkspaceId: String,
        sourceReviewEventIds: [String]
    ) throws -> [WorkspaceForkReviewEventRow] {
        guard sourceReviewEventIds.isEmpty == false else {
            return []
        }

        var rows: [WorkspaceForkReviewEventRow] = []
        var batchStartIndex: Int = 0
        while batchStartIndex < sourceReviewEventIds.count {
            let batchEndIndex: Int = min(
                batchStartIndex + workspaceForkReviewEventSelectBatchSize,
                sourceReviewEventIds.count
            )
            let batchReviewEventIds: [String] = Array(sourceReviewEventIds[batchStartIndex..<batchEndIndex])
            rows.append(contentsOf: try self.loadWorkspaceForkReviewEventBatch(
                sourceWorkspaceId: sourceWorkspaceId,
                sourceReviewEventIds: batchReviewEventIds
            ))
            batchStartIndex = batchEndIndex
        }

        return rows
    }

    private func loadWorkspaceForkReviewEventBatch(
        sourceWorkspaceId: String,
        sourceReviewEventIds: [String]
    ) throws -> [WorkspaceForkReviewEventRow] {
        guard sourceReviewEventIds.isEmpty == false else {
            return []
        }

        let placeholders: String = sourceReviewEventIds.map { _ in "?" }.joined(separator: ", ")
        let rows: [WorkspaceForkReviewEventRow] = try self.core.query(
            sql: """
            SELECT review_event_id, card_id, replica_id, client_event_id, rating, reviewed_at_client, reviewed_time_zone, reviewed_at_server
            FROM review_events
            WHERE workspace_id = ? AND review_event_id IN (\(placeholders))
            ORDER BY review_event_id ASC
            """,
            values: [.text(sourceWorkspaceId)] + sourceReviewEventIds.map { sourceReviewEventId in
                .text(sourceReviewEventId)
            }
        ) { statement in
            WorkspaceForkReviewEventRow(
                sourceReviewEventId: DatabaseCore.columnText(statement: statement, index: 0),
                sourceCardId: DatabaseCore.columnText(statement: statement, index: 1),
                replicaId: DatabaseCore.columnText(statement: statement, index: 2),
                clientEventId: DatabaseCore.columnText(statement: statement, index: 3),
                rating: DatabaseCore.columnInt64(statement: statement, index: 4),
                reviewedAtClient: DatabaseCore.columnText(statement: statement, index: 5),
                reviewedTimeZone: DatabaseCore.columnOptionalText(statement: statement, index: 6),
                reviewedAtServer: DatabaseCore.columnText(statement: statement, index: 7)
            )
        }

        let loadedReviewEventIds: Set<String> = Set(rows.map(\.sourceReviewEventId))
        let missingReviewEventIds: [String] = sourceReviewEventIds.filter { sourceReviewEventId in
            loadedReviewEventIds.contains(sourceReviewEventId) == false
        }
        guard missingReviewEventIds.isEmpty else {
            throw LocalStoreError.database(
                "Workspace identity fork is missing source review_event rows: \(missingReviewEventIds.joined(separator: ", "))"
            )
        }

        return rows
    }

    public init(core: DatabaseCore, workspaceSettingsStore: WorkspaceSettingsStore, shellStore: WorkspaceShellStore, mediaTransferStore: MediaTransferStore, outboxRewriter: WorkspaceOutboxRewriter) {
        self.core = core
        self.workspaceSettingsStore = workspaceSettingsStore
        self.shellStore = shellStore
        self.mediaTransferStore = mediaTransferStore
        self.outboxRewriter = outboxRewriter
    }
}
