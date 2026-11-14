import Foundation
import LingroveNotebook

/// One pinned review read borrows these rows for assembly. Query count stays independent of
/// the number of enrolled Cards; decoding and queue admission still use the existing writers'
/// value contracts. This temporary packet is never a durable cache or a second source of truth.
struct NotebookReviewReadRows {
    let exercises: [UUID: [LingroveNotebookReviewExercise]]
    let cards: [String: Card]
    let unavailable: Set<String>
    let undoable: Set<String>

    init(core: DatabaseCore, scope: LingroveNotebookSnapshot) throws {
        let workspace = SQLiteValue.text(scope.workspaceId)
        let rows = try core.query(sql: """
            SELECT exercise.enrollment_id,exercise.card_id,exercise.link_id,exercise.created_at
            FROM notebook_review_exercises exercise
            JOIN notebook_review_enrollments enrollment USING(workspace_id,enrollment_id)
            WHERE exercise.workspace_id=? AND enrollment.notebook_id=?
            ORDER BY exercise.enrollment_id,exercise.created_at,exercise.card_id
            """, values: [workspace, .text(scope.notebookId.uuidString)]) { row in
            guard let owner = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)),
                  let link = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 2)) else {
                throw VocabularyError.invalidArchive
            }
            return LingroveNotebookReviewExercise(enrollmentId: owner,
                cardId: DatabaseCore.columnText(statement: row, index: 1), linkId: link,
                createdAt: DatabaseCore.columnText(statement: row, index: 3))
        }
        exercises = Dictionary(grouping: rows, by: \.enrollmentId)
        let store = CardStore(core: core)
        let loaded = try core.query(sql: """
            SELECT \(cardStoreSelectColumnsSQL) FROM cards WHERE workspace_id=? AND deleted_at IS NULL
              AND card_id IN (SELECT card_id FROM notebook_note_cards WHERE workspace_id=?)
            """, values: [workspace, workspace]) { try store.mapCard(statement: $0) }
        cards = Dictionary(uniqueKeysWithValues: loaded.map { ($0.cardId, $0) })
        unavailable = Set(try core.query(sql: """
            SELECT card_id FROM notebook_review_material_state WHERE workspace_id=? AND status<>'ready'
            """, values: [workspace]) { DatabaseCore.columnText(statement: $0, index: 0) })
        undoable = Set(try core.query(sql: """
            SELECT rating.card_id FROM notebook_review_last_rating rating
            JOIN notebook_review_schedule_heads head USING(workspace_id,card_id)
            WHERE rating.workspace_id=? AND rating.operation_id=head.operation_id
            """, values: [workspace]) { DatabaseCore.columnText(statement: $0, index: 0) })
    }
}
