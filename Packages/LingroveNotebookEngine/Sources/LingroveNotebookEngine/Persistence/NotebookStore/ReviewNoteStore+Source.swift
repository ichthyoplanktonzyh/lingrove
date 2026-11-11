import Foundation
import LingroveNotebook

extension ReviewNoteStore {
    /// Enrollment needs only the fields a template can render. Load them under the writer's
    /// version fence so a click cannot attach a card to a removed or reassigned sense.
    func source(for selection: VocabularySelection, workspace: String) throws -> (VocabularyEntry, VocabularySense) {
        let values: [SQLiteValue] = [.text(workspace), .text(selection.entryID.uuidString), .text(selection.senseID.uuidString)]
        let rows = try core.query(sql: """
            SELECT entry.payload_json,sense.payload_json,collection.payload_json
            FROM notebook_senses sense
            JOIN notebook_entries entry ON entry.workspace_id=sense.workspace_id AND entry.id=sense.parent_id
            JOIN notebook_collections collection ON collection.workspace_id=sense.workspace_id AND collection.sense_id=sense.id
            WHERE sense.workspace_id=? AND entry.id=? AND sense.id=?
            """, values: values) { row in
            let entry = try decodeSourcePayload(VocabularyEntry.self, DatabaseCore.columnText(statement: row, index: 0))
            var sense = try decodeSourcePayload(VocabularySense.self, DatabaseCore.columnText(statement: row, index: 1))
            let collection = try decodeSourcePayload(ReviewSourceCollection.self, DatabaseCore.columnText(statement: row, index: 2))
            guard entry.id == selection.entryID, sense.id == selection.senseID, collection.senseID == sense.id else {
                throw VocabularyError.invalidArchive
            }
            sense.note = collection.note
            sense.tags = collection.tags
            return (entry, sense)
        }
        guard var (entry, sense) = rows.first else { throw VocabularyError.editConflict }
        let senseValues: [SQLiteValue] = [.text(workspace), .text(sense.id.uuidString)]
        sense.content = try core.query(sql: """
            SELECT block.payload_json FROM notebook_collections collection
            JOIN notebook_blocks block ON block.workspace_id=collection.workspace_id AND block.parent_id=collection.id
            WHERE collection.workspace_id=? AND collection.sense_id=? ORDER BY block.position
            """, values: senseValues) {
            try decodeSourcePayload(VocabularyContentBlock.self, DatabaseCore.columnText(statement: $0, index: 0))
        }
        sense.examples = try core.query(sql: """
            SELECT usage.payload_json,occurrence.payload_json,source.payload_json FROM notebook_usages usage
            JOIN notebook_occurrences occurrence ON occurrence.workspace_id=usage.workspace_id AND occurrence.id=usage.occurrence_id
            JOIN notebook_sources source ON source.workspace_id=occurrence.workspace_id AND source.id=occurrence.parent_id
            WHERE usage.workspace_id=? AND usage.sense_id=? AND usage.status='accepted' ORDER BY usage.position
            """, values: senseValues) { row in
            let claim = try decodeSourcePayload(VocabularyInterpretation.self, DatabaseCore.columnText(statement: row, index: 0))
            let occurrence = try decodeSourcePayload(VocabularySourceOccurrence.self, DatabaseCore.columnText(statement: row, index: 1))
            let source = try decodeSourcePayload(VocabularySourceSnapshot.self, DatabaseCore.columnText(statement: row, index: 2))
            guard claim.senseID == sense.id, claim.status == .accepted, claim.occurrenceID == occurrence.id,
                  occurrence.sourceID == source.id else { throw VocabularyError.invalidArchive }
            return VocabularyNotebookProjection.example(claim, occurrence: occurrence, source: source)
        }
        entry.senses = [sense]
        return (entry, sense)
    }

    private func decodeSourcePayload<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try core.decoder.decode(type, from: Data(json.utf8))
    }
}

/// The collection row owns these two template fields. Blocks and accepted evidence are read
/// separately, so enrollment never decodes the source's Anki bindings or other senses.
private struct ReviewSourceCollection: Decodable {
    let senseID: UUID
    let note: String
    let tags: [String]
}
