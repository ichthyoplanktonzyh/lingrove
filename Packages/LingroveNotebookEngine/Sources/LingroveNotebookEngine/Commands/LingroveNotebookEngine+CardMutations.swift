import Foundation
import LingroveNotebook

extension LingroveNotebookEngine {
    public func saveCard(
        workspaceId: String,
        input: CardEditorInput,
        cardId: String?,
        mediaAssetIdsReadyForUpload: Set<String>,
        notebookDraft: LingroveNotebookCardDraft? = nil
    ) throws -> Card {
        if let notebookDraft {
            guard cardId == nil, workspaceId == notebookDraft.source.workspaceId else { throw VocabularyError.editConflict }
            return try self.saveNewLingroveNotebookCard(draft: notebookDraft, input: input,
                mediaAssetIdsReadyForUpload: mediaAssetIdsReadyForUpload)
        }
        try self.cardStore.validateCardInput(input: input)

        return try self.core.inTransaction {
            let now = nowIsoTimestamp()
            let cloudSettings = try self.workspaceSettingsStore.loadCloudSettings()
            let persistedCard = try self.persistCardMutation(
                workspaceId: workspaceId,
                input: input,
                initialMetadata: nil,
                cardId: cardId,
                cloudSettings: cloudSettings,
                now: now
            )
            // Card bytes keep the original authenticated media transfer queue; notebook
            // ownership still gates publishing the Card itself through the held lane.
            try self.prepareCardMediaUploadsAfterSave(
                workspaceId: workspaceId,
                input: input,
                mediaAssetIdsReadyForUpload: mediaAssetIdsReadyForUpload,
                createdAt: now
            )
            return persistedCard
        }
    }

    public func createCards(workspaceId: String, inputs: [CardEditorInput]) throws -> [Card] {
        try self.validateCardBatchCount(count: inputs.count)
        for input in inputs {
            try self.cardStore.validateCardInput(input: input)
        }

        return try self.core.inTransaction {
            let now = nowIsoTimestamp()
            let cloudSettings = try self.workspaceSettingsStore.loadCloudSettings()
            var createdCards: [Card] = []
            createdCards.reserveCapacity(inputs.count)

            for input in inputs {
                createdCards.append(
                    try self.persistCardMutation(
                        workspaceId: workspaceId,
                        input: input,
                        initialMetadata: nil,
                        cardId: nil,
                        cloudSettings: cloudSettings,
                        now: now
                    )
                )
            }

            return createdCards
        }
    }

    public func deleteCard(workspaceId: String, cardId: String) throws -> Card {
        return try self.core.inTransaction {
            let now = nowIsoTimestamp()
            let cloudSettings = try self.workspaceSettingsStore.loadCloudSettings()
            return try self.persistDeletedCard(
                workspaceId: workspaceId,
                cardId: cardId,
                cloudSettings: cloudSettings,
                now: now
            )
        }
    }

    public func updateCards(workspaceId: String, updates: [CardUpdateInput]) throws -> [Card] {
        try self.validateCardBatchCount(count: updates.count)
        try self.validateUniqueCardIds(cardIds: updates.map { update in
            update.cardId
        })
        for update in updates {
            try self.cardStore.validateCardInput(input: update.input)
        }

        return try self.core.inTransaction {
            let now = nowIsoTimestamp()
            let cloudSettings = try self.workspaceSettingsStore.loadCloudSettings()
            var updatedCards: [Card] = []
            updatedCards.reserveCapacity(updates.count)

            for update in updates {
                updatedCards.append(
                    try self.persistCardMutation(
                        workspaceId: workspaceId,
                        input: update.input,
                        initialMetadata: nil,
                        cardId: update.cardId,
                        cloudSettings: cloudSettings,
                        now: now
                    )
                )
            }

            return updatedCards
        }
    }

    public func deleteCards(workspaceId: String, cardIds: [String]) throws -> BulkDeleteCardsResult {
        try self.validateCardBatchCount(count: cardIds.count)
        try self.validateUniqueCardIds(cardIds: cardIds)

        return try self.core.inTransaction {
            let now = nowIsoTimestamp()
            let cloudSettings = try self.workspaceSettingsStore.loadCloudSettings()

            for cardId in cardIds {
                _ = try self.persistDeletedCard(
                    workspaceId: workspaceId,
                    cardId: cardId,
                    cloudSettings: cloudSettings,
                    now: now
                )
            }

            return BulkDeleteCardsResult(
                deletedCardIds: cardIds,
                deletedCount: cardIds.count
            )
        }
    }

    public func persistCardMutation(
        workspaceId: String,
        input: CardEditorInput,
        initialMetadata: CardMetadata?,
        cardId: String?,
        cloudSettings: CloudSettings,
        now: String,
        newCardID: String? = nil
    ) throws -> Card {
        let operationId = UUID().uuidString.lowercased()
        let isInitialCreate = cardId == nil
        // Fresh creates install the card into the review queue; text/tag edits
        // don't touch FSRS fields. Kept as two separate locals — both happen to
        // derive from `cardId == nil` today but encode independent intents.
        let reviewScheduleImpact = cardId == nil
        let persistedCard = try self.cardStore.saveCard(
            workspaceId: workspaceId,
            input: input,
            initialMetadata: initialMetadata,
            cardId: cardId,
            installationId: cloudSettings.installationId,
            operationId: operationId,
            now: now, newCardID: newCardID
        )
        try self.outboxStore.enqueueCardUpsertOperation(
            workspaceId: workspaceId,
            installationId: cloudSettings.installationId,
            operationId: operationId,
            clientUpdatedAt: now,
            card: persistedCard,
            isInitialCreate: isInitialCreate,
            reviewScheduleImpact: reviewScheduleImpact
        )
        return persistedCard
    }

    private func persistDeletedCard(
        workspaceId: String,
        cardId: String,
        cloudSettings: CloudSettings,
        now: String
    ) throws -> Card {
        let operationId = UUID().uuidString.lowercased()
        let deletedCard = try self.cardStore.deleteCard(
            workspaceId: workspaceId,
            cardId: cardId,
            installationId: cloudSettings.installationId,
            operationId: operationId,
            now: now
        )
        try self.outboxStore.enqueueCardUpsertOperation(
            workspaceId: workspaceId,
            installationId: cloudSettings.installationId,
            operationId: operationId,
            clientUpdatedAt: now,
            card: deletedCard,
            isInitialCreate: false,
            reviewScheduleImpact: true
        )
        return deletedCard
    }

    public func validateCardBatchCount(count: Int) throws {
        if count < 1 {
            throw LocalStoreError.validation("Card batch must contain at least one item")
        }

        if count > 100 {
            throw LocalStoreError.validation("Card batch must contain at most 100 items")
        }
    }

    public func validateUniqueCardIds(cardIds: [String]) throws {
        let uniqueCardIds = Set(cardIds)
        if uniqueCardIds.count != cardIds.count {
            throw LocalStoreError.validation("Card batch must not contain duplicate cardId values")
        }
    }

    private func prepareCardMediaUploadsAfterSave(
        workspaceId: String,
        input: CardEditorInput,
        mediaAssetIdsReadyForUpload: Set<String>,
        createdAt: String
    ) throws {
        guard mediaAssetIdsReadyForUpload.isEmpty == false else {
            return
        }

        let referencedMediaAssetIds = managedMediaAssetIdsReferencedInMarkdown(text: input.frontText)
            .union(managedMediaAssetIdsReferencedInMarkdown(text: input.backText))
            .intersection(mediaAssetIdsReadyForUpload)
        for mediaAssetId in referencedMediaAssetIds.sorted() {
            _ = try self.prepareReferencedMediaAssetUploadForSavedCard(
                workspaceId: workspaceId,
                mediaAssetId: mediaAssetId,
                createdAt: createdAt
            )
        }
    }
}
