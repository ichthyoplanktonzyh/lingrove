import Foundation

/// A persisted one-step undo belongs to its original rating and survives app restart. Restoring
/// only scheduler columns preserves later authored faces. A subsequent rating supersedes this
/// local affordance; the server also checks the causal target before restoring a remote head.
extension LingroveNotebookEngine {
    public func undoLastNotebookRating(workspaceId: String, cardId: String, generation: String? = nil) throws {
        try core.inTransaction {
            let snapshot = try lingroveNotebookStore.readSnapshot(workspaceId: workspaceId)
            try lingroveNotebookCardLinkStore.requireActiveScope(workspaceId: workspaceId, notebookId: snapshot.notebookId)
            if let generation, snapshot.generation != generation { throw CancellationError() }
            let rows = try core.query(sql: "SELECT event_id,operation_id,previous_card_json FROM notebook_review_last_rating WHERE workspace_id=? AND card_id=?", values: [.text(workspaceId), .text(cardId)]) {
                (DatabaseCore.columnText(statement: $0, index: 0), DatabaseCore.columnText(statement: $0, index: 1), DatabaseCore.columnText(statement: $0, index: 2))
            }
            guard let row = rows.first else { throw LocalStoreError.validation("No rating is available to undo") }
            _ = try cardStore.loadCard(workspaceId: workspaceId, cardId: cardId)
            let head = try core.scalarOptionalText(sql: "SELECT operation_id FROM notebook_review_schedule_heads WHERE workspace_id=? AND card_id=?", values: [.text(workspaceId), .text(cardId)])
            guard head == row.1 else { throw LocalStoreError.validation("This exercise changed after the rating") }
            let old = try core.decoder.decode(Card.self, from: Data(row.2.utf8))
            let id = UUID().uuidString.lowercased(), now = nowIsoTimestamp()
            try core.execute(sql: """
                UPDATE cards SET due_at=?,due_at_millis=?,reps=?,lapses=?,fsrs_card_state=?,fsrs_step_index=?,fsrs_stability=?,fsrs_difficulty=?,
                fsrs_last_reviewed_at=?,fsrs_last_reviewed_at_millis=?,fsrs_scheduled_days=?,last_operation_id=?,updated_at=? WHERE workspace_id=? AND card_id=?
                """, values: [old.dueAt.map(SQLiteValue.text) ?? .null, old.dueAt.flatMap(parseStrictIsoTimestampEpochMillis).map(SQLiteValue.integer) ?? .null,
                    .integer(Int64(old.reps)), .integer(Int64(old.lapses)), .text(old.fsrsCardState.rawValue), old.fsrsStepIndex.map { .integer(Int64($0)) } ?? .null,
                    old.fsrsStability.map(SQLiteValue.real) ?? .null, old.fsrsDifficulty.map(SQLiteValue.real) ?? .null,
                    old.fsrsLastReviewedAt.map(SQLiteValue.text) ?? .null, old.fsrsLastReviewedAt.flatMap(parseStrictIsoTimestampEpochMillis).map(SQLiteValue.integer) ?? .null,
                    old.fsrsScheduledDays.map { .integer(Int64($0)) } ?? .null, .text(id), .text(now), .text(workspaceId), .text(cardId)])
            try core.execute(sql: "INSERT INTO notebook_review_undo(workspace_id,undo_id,card_id,event_id,target_operation_id,previous_card_json,created_at,pending) VALUES(?,?,?,?,?,?,?,1)",
                values: [.text(workspaceId), .text(id), .text(cardId), .text(row.0), .text(row.1), .text(row.2), .text(now)])
            try core.execute(sql: "UPDATE notebook_review_schedule_heads SET operation_id=? WHERE workspace_id=? AND card_id=?", values: [.text(id), .text(workspaceId), .text(cardId)])
            try core.execute(sql: "DELETE FROM notebook_review_last_rating WHERE workspace_id=? AND card_id=?", values: [.text(workspaceId), .text(cardId)])
        }
    }
}
