import Foundation
import LingroveNotebook

/// The native notebook entrance has narrower ownership than the generic Card entrance. This
/// adapter reuses the enrollment snapshot, admission gate and queue ordering instead of making
/// every arbitrary workspace Card appear to be personally selected language material.
extension LingroveNotebookEngine {
    public func loadBuiltInNotebookReview(scope: LingroveNotebookSnapshot, now: Date) throws -> NotebookBuiltInReviewSnapshot {
        let review = try loadLingroveNotebookReviewSnapshot(scope: scope)
        return try core.inReadTransaction {
            try requireCurrentScopeInTransaction(scope, requireRevision: true)
            // The public review read owns its transaction. Validate its immutable inputs in
            // this second read transaction, rather than nesting BEGIN or copying its grouping
            // algorithm. A concurrent change fails closed and the host simply reads again.
            let enrollments = review.groups.values.flatMap(\.enrollments).sorted { $0.id.uuidString < $1.id.uuidString }
            let currentEnrollments = try lingroveNotebookReviewStore.load(workspaceId: scope.workspaceId)
                .filter { $0.notebookId == scope.notebookId }.sorted { $0.id.uuidString < $1.id.uuidString }
            guard currentEnrollments == enrollments,
                  try lingroveNotebookCardLinkStore.load(workspaceId: scope.workspaceId) == review.links else {
                throw VocabularyError.editConflict
            }
            var cards: [String: Card] = [:]
            for card in review.groups.values.flatMap(\.cards) {
                let stored = try cardStore.loadOptionalCardIncludingDeleted(workspaceId: scope.workspaceId, cardId: card.cardId)
                guard try requireValidBuiltInReviewCard(stored) == card else {
                    throw VocabularyError.editConflict
                }
                cards[card.cardId] = card
            }
            let excluded = try cardStore.loadNotebookExcludedReviewCardIds(workspaceId: scope.workspaceId)
            let activeIDs = Set(review.groups.values.filter { $0.status == .active }.flatMap(\.cards).map(\.cardId))
            let linkedIDs = Set(review.links.filter {
                $0.deletedAt == nil && $0.source.notebookId == scope.notebookId
            }.map(\.cardId))
            let eligibleIDs = activeIDs.intersection(linkedIDs).subtracting(excluded)
            let queue = sortCardsForReviewQueue(cards: cards.values.filter { eligibleIDs.contains($0.cardId) }, now: now)
            let history = try builtInReviewHistory(scope: scope)
            let counts = try builtInReviewHistoryCounts(scope: scope)
            let undo = try builtInReviewUndo(scope: scope, cards: cards)
            let groups = Array(review.groups.values)
            return .init(scope: scope, review: review,
                schedulerSettings: try workspaceSettingsStore.loadWorkspaceSchedulerSettings(workspaceId: scope.workspaceId),
                queue: queue, eligibleCardIDs: eligibleIDs,
                statistics: .init(activeSenses: groups.filter { $0.status == .active }.count,
                    pausedSenses: groups.filter { $0.status == .paused }.count,
                    withdrawnSenses: groups.filter { $0.status == .withdrawn }.count,
                    exercises: cards.count, readyExercises: queue.count,
                    newExercises: cards.values.filter { eligibleIDs.contains($0.cardId) && $0.dueAt == nil }.count,
                    reviewedExercises: cards.values.filter { $0.reps > 0 }.count,
                    ratingRecords: counts.ratings, undoneRatings: counts.undos),
                undoByCardID: undo, recentHistory: history, noteCards: try ReviewNoteStore(core: core).cardModels(scope: scope),
                noteTypes: try ReviewNoteStore(core: core).types(workspace: scope.workspaceId),
                defaultNoteType: try ReviewNoteStore(core: core).defaultType(workspace: scope.workspaceId))
        }
    }

    private func builtInReviewUndo(scope: LingroveNotebookSnapshot, cards: [String: Card]) throws
        -> [String: NotebookBuiltInReviewUndo] {
        let rows = try core.query(sql: """
            SELECT rating.card_id, rating.operation_id FROM notebook_review_last_rating rating
            JOIN notebook_review_schedule_heads head USING(workspace_id,card_id)
            WHERE rating.workspace_id=? AND rating.operation_id=head.operation_id
            """, values: [.text(scope.workspaceId)]) {
            (DatabaseCore.columnText(statement: $0, index: 0), DatabaseCore.columnText(statement: $0, index: 1))
        }
        var result: [String: NotebookBuiltInReviewUndo] = [:]
        for (id, operation) in rows {
            guard let card = cards[id], card.fsrsLastReviewedAt != nil else { continue }
            result[id] = .init(cardID: id, cardOperationID: card.lastOperationId, ratingOperationID: operation)
        }
        return result
    }

    private func builtInReviewHistoryCounts(scope: LingroveNotebookSnapshot) throws -> (ratings: Int, undos: Int) {
        let values: [SQLiteValue] = [.text(scope.workspaceId), .text(scope.notebookId.uuidString)]
        let ratings = try core.scalarInt(sql: """
            SELECT COUNT(*) FROM review_events event WHERE event.workspace_id=? AND
            EXISTS (SELECT 1 FROM notebook_review_exercises exercise
                JOIN notebook_review_enrollments enrollment USING(workspace_id,enrollment_id)
                WHERE exercise.workspace_id=event.workspace_id AND exercise.card_id=event.card_id AND enrollment.notebook_id=?)
            """, values: values)
        let undos = try core.scalarInt(sql: """
            SELECT COUNT(*) FROM notebook_review_undo undo WHERE undo.workspace_id=? AND
            EXISTS (SELECT 1 FROM notebook_review_exercises exercise
                JOIN notebook_review_enrollments enrollment USING(workspace_id,enrollment_id)
                WHERE exercise.workspace_id=undo.workspace_id AND exercise.card_id=undo.card_id AND enrollment.notebook_id=?)
            """, values: values)
        return (ratings, undos)
    }

    private func builtInReviewHistory(scope: LingroveNotebookSnapshot) throws -> [NotebookBuiltInReviewHistory] {
        try core.query(sql: """
            SELECT event.review_event_id,event.card_id,event.rating,event.reviewed_at_client,
                EXISTS(SELECT 1 FROM notebook_review_undo undo WHERE undo.workspace_id=event.workspace_id
                    AND undo.event_id=event.review_event_id)
            FROM review_events event WHERE event.workspace_id=? AND
                EXISTS(SELECT 1 FROM notebook_review_exercises exercise
                    JOIN notebook_review_enrollments enrollment USING(workspace_id,enrollment_id)
                    WHERE exercise.workspace_id=event.workspace_id AND exercise.card_id=event.card_id AND enrollment.notebook_id=?)
            ORDER BY event.reviewed_at_client DESC,event.review_event_id DESC LIMIT 12
            """, values: [.text(scope.workspaceId), .text(scope.notebookId.uuidString)]) {
            guard let rating = ReviewRating(rawValue: Int(DatabaseCore.columnInt64(statement: $0, index: 2))) else {
                throw VocabularyError.invalidArchive
            }
            return .init(id: DatabaseCore.columnText(statement: $0, index: 0),
                cardID: DatabaseCore.columnText(statement: $0, index: 1), rating: rating,
                reviewedAt: DatabaseCore.columnText(statement: $0, index: 3),
                wasUndone: DatabaseCore.columnInt64(statement: $0, index: 4) != 0)
        }
    }
}
