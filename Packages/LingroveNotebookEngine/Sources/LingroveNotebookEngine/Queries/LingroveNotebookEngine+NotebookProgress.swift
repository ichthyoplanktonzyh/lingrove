import Foundation
import LingroveNotebook
import SQLite3

/// Read-only notebook statistics, separate from the command/session facade. The caller owns
/// the connection lifetime; every content read below belongs to one deferred SQL snapshot.
/// No notebook bootstrap, scheduler repair, review submission or cloud refresh is invoked.
extension LingroveNotebookEngine {
    public func notebookProgressReadFence() throws -> NotebookProgressReadFence {
        try core.inReadTransaction {
            let before = try core.notebookCacheToken()
            let scope = try notebookProgressScopeInTransaction()
            guard try core.notebookCacheToken() == before else { throw VocabularyError.editConflict }
            return .init(scope: scope, externalVersion: before.externalVersion,
                connectionChanges: before.connectionChanges)
        }
    }

    public func loadNotebookProgress(scope: NotebookProgressScope, now: Date,
                                     calendar: Calendar) throws -> NotebookProgressSnapshot {
        try core.inReadTransaction {
            try Task.checkCancellation()
            guard try notebookProgressScopeInTransaction() == scope else { throw VocabularyError.editConflict }
            guard let notebookID = scope.notebookID else {
                return try NotebookProgressAggregation.make(scope: scope, events: [], dueExercises: [],
                    undoneReviews: 0, enrolledSenses: 0, activeSenses: 0, exercises: 0, now: now, userCalendar: calendar)
            }
            let snapshot = try lingroveNotebookStore.readSnapshot(workspaceId: scope.workspaceID)
            guard snapshot.notebookId == notebookID, snapshot.revision == scope.revision,
                  snapshot.generation == scope.generation else { throw VocabularyError.editConflict }
            let enrollmentValues = try lingroveNotebookReviewStore.load(workspaceId: scope.workspaceID)
                .filter { $0.notebookId == notebookID }
            var grouped: [UUID: [LingroveNotebookReviewEnrollment]] = [:]
            for enrollment in enrollmentValues {
                let senseID = LingroveNotebookCardMaterial.resolvedSelection(source: enrollment.source,
                    snapshot: snapshot)?.senseID ?? enrollment.senseId
                grouped[senseID, default: []].append(enrollment)
            }
            let values: [SQLiteValue] = [.text(scope.workspaceID), .text(notebookID.uuidString)]
            // EXISTS follows the durable exercise mapping rather than current Cards or source
            // rows. Withdrawn, merged, missing and deleted material therefore retain history.
            let ownedEvent = """
                EXISTS (SELECT 1 FROM notebook_review_exercises exercise
                    JOIN notebook_review_enrollments enrollment USING(workspace_id,enrollment_id)
                    WHERE exercise.workspace_id=event.workspace_id AND exercise.card_id=event.card_id
                        AND enrollment.notebook_id=?)
                """
            let events = try core.query(sql: """
                SELECT event.review_event_id,event.reviewed_at_client,event.reviewed_time_zone,event.rating
                FROM review_events event WHERE event.workspace_id=? AND \(ownedEvent)
                    AND NOT EXISTS(SELECT 1 FROM notebook_review_undo undo
                        WHERE undo.workspace_id=event.workspace_id AND undo.event_id=event.review_event_id)
                ORDER BY event.reviewed_at_client,event.review_event_id
                """, values: values) { row -> NotebookProgressEvent in
                try Task.checkCancellation()
                guard let rating = ReviewRating(rawValue: Int(DatabaseCore.columnInt64(statement: row, index: 3))) else {
                    throw VocabularyError.invalidArchive
                }
                return .init(id: DatabaseCore.columnText(statement: row, index: 0),
                    reviewedAt: DatabaseCore.columnText(statement: row, index: 1),
                    timeZone: DatabaseCore.columnOptionalText(statement: row, index: 2), rating: rating)
            }
            let undone = try core.scalarInt(sql: """
                SELECT COUNT(*) FROM review_events event WHERE event.workspace_id=? AND \(ownedEvent)
                    AND EXISTS(SELECT 1 FROM notebook_review_undo undo
                        WHERE undo.workspace_id=event.workspace_id AND undo.event_id=event.review_event_id)
                """, values: values)
            let liveExercises = try core.scalarInt(sql: """
                SELECT COUNT(*) FROM cards WHERE cards.workspace_id=? AND cards.deleted_at IS NULL
                    AND EXISTS(SELECT 1 FROM notebook_review_exercises exercise
                        JOIN notebook_review_enrollments enrollment USING(workspace_id,enrollment_id)
                        WHERE exercise.workspace_id=cards.workspace_id AND exercise.card_id=cards.card_id
                            AND enrollment.notebook_id=?)
                """, values: values)
            let due = try notebookProgressDueExercises(values: values)
            return try NotebookProgressAggregation.make(scope: scope, events: events, dueExercises: due,
                undoneReviews: undone, enrolledSenses: grouped.count,
                activeSenses: grouped.values.filter { $0.contains { $0.status == .active } }.count,
                exercises: liveExercises, now: now, userCalendar: calendar)
        }
    }

    /// Reuse the queue's participation/material predicate, then narrow it to this notebook's
    /// managed exercises. Generic Cards and merely linked Cards never enter this forecast.
    private func notebookProgressDueExercises(values: [SQLiteValue]) throws -> [NotebookProgressDueExercise] {
        try core.query(sql: """
            SELECT \(cardStoreSelectColumnsSQL),due_at_millis FROM cards
            WHERE cards.workspace_id=? AND cards.deleted_at IS NULL
                AND \(cardStoreNotebookReviewEligibilitySQL)
                AND EXISTS(SELECT 1 FROM notebook_review_exercises exercise
                    JOIN notebook_review_enrollments enrollment USING(workspace_id,enrollment_id)
                    JOIN notebook_card_links link ON link.workspace_id=exercise.workspace_id AND link.link_id=exercise.link_id
                    WHERE exercise.workspace_id=cards.workspace_id AND exercise.card_id=cards.card_id
                        AND enrollment.notebook_id=? AND link.notebook_id=enrollment.notebook_id
                        AND link.card_id=cards.card_id AND link.deleted_at IS NULL)
            """, values: values) { row in
            try Task.checkCancellation()
            let card = try cardStore.mapCard(statement: row)
            guard invalidFsrsStateReason(card: card) == nil else {
                throw LocalStoreError.validation("Saved exercise scheduling state is invalid")
            }
            if let dueAt = card.dueAt {
                guard let date = parseIsoTimestamp(value: dueAt), sqlite3_column_type(row, 22) == SQLITE_INTEGER else {
                    throw LocalStoreError.validation("Saved exercise has an invalid due timestamp")
                }
                let millis = DatabaseCore.columnInt64(statement: row, index: 22)
                guard abs(Double(millis) - date.timeIntervalSince1970 * 1_000) < 1 else {
                    throw LocalStoreError.validation("Saved exercise due timestamp is inconsistent")
                }
                return .init(dueMillis: millis)
            }
            guard sqlite3_column_type(row, 22) == SQLITE_NULL else {
                throw LocalStoreError.validation("A new exercise unexpectedly has a due timestamp")
            }
            return .init(dueMillis: nil)
        }
    }

    /// This helper is intentionally transaction-free: both fence and full snapshot own their
    /// enclosing transaction. Keeping BEGIN at those public boundaries prevents nested reads.
    private func notebookProgressScopeInTransaction() throws -> NotebookProgressScope {
        let rows = try core.query(sql: """
            SELECT settings.active_workspace_id,notebook.notebook_id,notebook.revision,binding.generation
            FROM app_local_settings settings
            LEFT JOIN notebook_state notebook ON notebook.workspace_id=settings.active_workspace_id
            LEFT JOIN notebook_window_binding binding ON binding.settings_id=settings.settings_id
            WHERE settings.settings_id=1
            """, values: []) { row -> NotebookProgressScope in
            guard let workspace = DatabaseCore.columnOptionalText(statement: row, index: 0), !workspace.isEmpty,
                  let generation = DatabaseCore.columnOptionalText(statement: row, index: 3), !generation.isEmpty else {
                throw VocabularyError.editConflict
            }
            guard let notebook = DatabaseCore.columnOptionalText(statement: row, index: 1) else {
                guard sqlite3_column_type(row, 2) == SQLITE_NULL else { throw VocabularyError.invalidArchive }
                return .init(workspaceID: workspace, notebookID: nil, revision: nil, generation: generation)
            }
            let revision = DatabaseCore.columnInt64(statement: row, index: 2)
            guard let id = UUID(uuidString: notebook), sqlite3_column_type(row, 2) == SQLITE_INTEGER,
                  revision >= 0 else { throw VocabularyError.invalidArchive }
            return .init(workspaceID: workspace, notebookID: id, revision: UInt64(revision), generation: generation)
        }
        guard let scope = rows.first else { throw VocabularyError.editConflict }
        return scope
    }
}
