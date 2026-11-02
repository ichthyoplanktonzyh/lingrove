import Foundation
import LingroveNotebook

extension LingroveNotebookEngine {
    // Keep in sync with apps/backend/src/cards/review/reviews.ts::submitReview.
    public func submitReview(workspaceId: String, reviewSubmission: ReviewSubmission, scope: LingroveNotebookSnapshot? = nil,
        expectedCardOperationID: String? = nil, validateCurrentState: (() throws -> Void)? = nil,
        onTransaction: (() throws -> Void)? = nil) throws -> Card {
        try Task.checkCancellation()
        return try self.core.inTransaction {
            try Task.checkCancellation()
            // A native saved-screen fence must run before legacy Card reads can normalize an
            // invalid row. This hook borrows the same writer lock; it never spans an await.
            try validateCurrentState?()
            if let scope { try requireCurrentScopeInTransaction(scope, requireRevision: false) }
            let card = try self.cardStore.loadCard(workspaceId: workspaceId, cardId: reviewSubmission.cardId)
            if let expectedCardOperationID, card.lastOperationId != expectedCardOperationID { throw VocabularyError.editConflict }
            // A rating queued by an old screen cannot write after a pause/withdrawal committed.
            // Admission is separate from FSRS; the scheduler and append-only history stay native.
            guard try !self.cardStore.loadNotebookExcludedReviewCardIds(workspaceId: workspaceId).contains(card.cardId) else {
                throw LocalStoreError.validation("This sense is not active in review")
            }
            if try lingroveNotebookCardLinkStore.isHeld(workspaceId: workspaceId, cardId: card.cardId) {
                let current = try lingroveNotebookStore.readSnapshot(workspaceId: workspaceId)
                try lingroveNotebookCardLinkStore.requireActiveScope(workspaceId: workspaceId, notebookId: current.notebookId)
            }
            let schedulerSettings = try self.workspaceSettingsStore.loadWorkspaceSchedulerSettings(workspaceId: workspaceId)
            guard let reviewedAtClient = parseIsoTimestamp(value: reviewSubmission.reviewedAtClient) else {
                throw LocalStoreError.validation("reviewedAtClient must be a valid ISO timestamp")
            }
            let schedule = try computeReviewSchedule(
                card: card,
                settings: schedulerSettings,
                rating: reviewSubmission.rating,
                now: reviewedAtClient
            )
            let cloudSettings = try self.workspaceSettingsStore.loadCloudSettings()
            let reviewEventOperationId = UUID().uuidString.lowercased()
            let cardOperationId = UUID().uuidString.lowercased()
            let reviewEventId = UUID().uuidString.lowercased()
            let clientEventId = UUID().uuidString.lowercased()
            let reviewedAtServer = nowIsoTimestamp()

            let reviewEvent = try self.cardStore.appendReviewEvent(
                workspaceId: workspaceId,
                cardId: reviewSubmission.cardId,
                rating: reviewSubmission.rating,
                reviewedAtClient: reviewSubmission.reviewedAtClient,
                reviewedTimeZone: reviewSubmission.reviewedTimeZone,
                installationId: cloudSettings.installationId,
                reviewEventId: reviewEventId,
                clientEventId: clientEventId,
                reviewedAtServer: reviewedAtServer
            )

            let updatedCard = try self.cardStore.applyReviewSchedule(
                workspaceId: workspaceId,
                cardId: reviewSubmission.cardId,
                reviewSubmission: reviewSubmission,
                schedule: schedule,
                installationId: cloudSettings.installationId,
                operationId: cardOperationId,
                reviewedAtServer: reviewedAtServer
            )

            try self.outboxStore.enqueueReviewEventAppendOperation(
                workspaceId: workspaceId,
                installationId: cloudSettings.installationId,
                operationId: reviewEventOperationId,
                clientUpdatedAt: reviewSubmission.reviewedAtClient,
                reviewEvent: reviewEvent
            )

            try self.outboxStore.enqueueCardUpsertOperation(
                workspaceId: workspaceId,
                installationId: cloudSettings.installationId,
                operationId: cardOperationId,
                clientUpdatedAt: reviewSubmission.reviewedAtClient,
                card: updatedCard,
                isInitialCreate: false,
                reviewScheduleImpact: true
            )
            if try lingroveNotebookCardLinkStore.isHeld(workspaceId: workspaceId, cardId: card.cardId) {
                try core.execute(sql: "INSERT INTO notebook_review_schedule_heads(workspace_id,card_id,operation_id) VALUES(?,?,?) ON CONFLICT(workspace_id,card_id) DO UPDATE SET operation_id=excluded.operation_id", values: [.text(workspaceId), .text(card.cardId), .text(cardOperationId)])
                try core.execute(sql: "INSERT INTO notebook_review_last_rating(workspace_id,card_id,event_id,operation_id,previous_card_json) VALUES(?,?,?,?,?) ON CONFLICT(workspace_id,card_id) DO UPDATE SET event_id=excluded.event_id,operation_id=excluded.operation_id,previous_card_json=excluded.previous_card_json",
                    values: [.text(workspaceId), .text(card.cardId), .text(reviewEventId), .text(cardOperationId), .text(try core.encodeJsonString(value: card))])
            }
            try onTransaction?()
            return updatedCard
        }
    }

    // Keep in sync with apps/backend/src/scheduling/workspaceSettings.ts::updateWorkspaceSchedulerSettings.
    public func updateWorkspaceSchedulerSettings(
        workspaceId: String,
        desiredRetention: Double,
        learningStepsMinutes: [Int],
        relearningStepsMinutes: [Int],
        maximumIntervalDays: Int,
        enableFuzz: Bool
    ) throws {
        try self.core.inTransaction {
            let cloudSettings = try self.workspaceSettingsStore.loadCloudSettings()
            let operationId = UUID().uuidString.lowercased()
            let now = nowIsoTimestamp()
            let updatedSettings = try self.workspaceSettingsStore.updateWorkspaceSchedulerSettings(
                workspaceId: workspaceId,
                desiredRetention: desiredRetention,
                learningStepsMinutes: learningStepsMinutes,
                relearningStepsMinutes: relearningStepsMinutes,
                maximumIntervalDays: maximumIntervalDays,
                enableFuzz: enableFuzz,
                installationId: cloudSettings.installationId,
                operationId: operationId,
                now: now
            )
            try self.outboxStore.enqueueWorkspaceSchedulerSettingsUpsertOperation(
                workspaceId: workspaceId,
                installationId: cloudSettings.installationId,
                operationId: operationId,
                clientUpdatedAt: now,
                settings: updatedSettings
            )
        }
    }
}
