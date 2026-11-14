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

    init(core: DatabaseCore, scope: LingroveNotebookSnapshot, selecting senseIDs: Set<UUID>? = nil) throws {
        let workspace = SQLiteValue.text(scope.workspaceId)
        let senseJSON = try senseIDs.map { String(decoding: try core.encoder.encode($0.map(\.uuidString).sorted()), as: UTF8.self) }
        let selected = senseJSON == nil ? "" : " AND enrollment.sense_id IN (SELECT value FROM json_each(?))"
        let rows = try core.query(sql: """
            SELECT exercise.enrollment_id,exercise.card_id,exercise.link_id,exercise.created_at
            FROM notebook_review_exercises exercise
            JOIN notebook_review_enrollments enrollment USING(workspace_id,enrollment_id)
            WHERE exercise.workspace_id=? AND enrollment.notebook_id=?\(selected)
            ORDER BY exercise.enrollment_id,exercise.created_at,exercise.card_id
            """, values: [workspace, .text(scope.notebookId.uuidString)] + (senseJSON.map { [.text($0)] } ?? [])) { row in
            guard let owner = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)),
                  let link = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 2)) else {
                throw VocabularyError.invalidArchive
            }
            return LingroveNotebookReviewExercise(enrollmentId: owner,
                cardId: DatabaseCore.columnText(statement: row, index: 1), linkId: link,
                createdAt: DatabaseCore.columnText(statement: row, index: 3))
        }
        exercises = Dictionary(grouping: rows, by: \.enrollmentId)
        let cardJSON = senseIDs == nil ? nil : String(decoding: try core.encoder.encode(Set(rows.map(\.cardId)).sorted()), as: UTF8.self)
        let cardFilter = cardJSON == nil ? "" : " AND card_id IN (SELECT value FROM json_each(?))"
        let cardValues: [SQLiteValue] = cardJSON.map { [.text($0)] } ?? []
        let store = CardStore(core: core)
        let loaded = try core.query(sql: """
            SELECT \(cardStoreSelectColumnsSQL) FROM cards WHERE workspace_id=? AND deleted_at IS NULL
              AND card_id IN (SELECT card_id FROM notebook_note_cards WHERE workspace_id=?)\(cardFilter)
            """, values: [workspace, workspace] + cardValues) { try store.mapCard(statement: $0) }
        cards = Dictionary(uniqueKeysWithValues: loaded.map { ($0.cardId, $0) })
        unavailable = Set(try core.query(sql: """
            SELECT card_id FROM notebook_review_material_state WHERE workspace_id=? AND status<>'ready'\(cardFilter)
            """, values: [workspace] + cardValues) { DatabaseCore.columnText(statement: $0, index: 0) })
        undoable = Set(try core.query(sql: """
            SELECT rating.card_id FROM notebook_review_last_rating rating
            JOIN notebook_review_schedule_heads head USING(workspace_id,card_id)
            WHERE rating.workspace_id=? AND rating.operation_id=head.operation_id\(cardFilter.replacingOccurrences(of: " AND card_id", with: " AND rating.card_id"))
            """, values: [workspace] + cardValues) { DatabaseCore.columnText(statement: $0, index: 0) })
    }
}
