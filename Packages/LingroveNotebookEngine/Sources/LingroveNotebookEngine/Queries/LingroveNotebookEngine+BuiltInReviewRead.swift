import Foundation
import LingroveNotebook

/// The native notebook entrance has narrower ownership than the generic Card entrance. This
/// adapter reuses the enrollment snapshot, admission gate and queue ordering instead of making
/// every arbitrary workspace Card appear to be personally selected language material.
extension LingroveNotebookEngine {
    public func loadBuiltInNotebookReview(scope: LingroveNotebookSnapshot, now: Date) throws -> NotebookBuiltInReviewSnapshot {
        try loadBuiltInNotebookReview(version: .init(scope), now: now)
    }

    /// A host can reuse the corpus snapshot it already read from this database. The version
    /// binds its immutable content to this read transaction. Queue and history always come
    /// from storage because ratings and participation can change at the same corpus revision.
    public func loadBuiltInNotebookReview(version: LingroveNotebookVersion, now: Date,
                                          savedScope: LingroveNotebookSnapshot? = nil) throws -> NotebookBuiltInReviewSnapshot {
        try core.inReadTransaction {
            try Task.checkCancellation()
            guard try currentNotebookVersionInTransaction() == version else { throw VocabularyError.editConflict }
            let scope: LingroveNotebookSnapshot
            if let savedScope, LingroveNotebookVersion(savedScope) == version {
                scope = savedScope
            } else {
                scope = try lingroveNotebookStore.readSnapshot(workspaceId: version.workspaceId)
            }
            let review = try loadLingroveNotebookReviewSnapshotInTransaction(current: scope)
            var cards: [String: Card] = [:]
            for card in review.groups.values.flatMap(\.cards) {
                try Task.checkCancellation()
                cards[card.cardId] = try requireValidBuiltInReviewCard(card)
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
                undoByCardID: undo, recentHistory: history, noteCards: review.noteCards,
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
                    JOIN notebook_note_cards member ON member.workspace_id=exercise.workspace_id AND member.card_id=exercise.card_id
                WHERE exercise.workspace_id=event.workspace_id AND exercise.card_id=event.card_id AND enrollment.notebook_id=?)
            """, values: values)
        let undos = try core.scalarInt(sql: """
            SELECT COUNT(*) FROM notebook_review_undo undo WHERE undo.workspace_id=? AND
            EXISTS (SELECT 1 FROM notebook_review_exercises exercise
                JOIN notebook_review_enrollments enrollment USING(workspace_id,enrollment_id)
                    JOIN notebook_note_cards member ON member.workspace_id=exercise.workspace_id AND member.card_id=exercise.card_id
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
                    JOIN notebook_note_cards member ON member.workspace_id=exercise.workspace_id AND member.card_id=exercise.card_id
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
