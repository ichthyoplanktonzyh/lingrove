import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec

extension NotebookEntryAdmission {
    /// The certificate supplies the complete set; a local edit adds its new references and
    /// drops an old one only after checking for owners outside this packet. This is an
    /// indexed canonical lookup, not another authoritative reference-counting database.
    func media(after: Set<VocabularyImageReference>, before: Set<VocabularyImageReference>,
               rows: [VocabularyPersistenceRow], checkpoint: NotebookEntryCheckpoint) throws -> Set<VocabularyImageReference> {
        var result = checkpoint.media.union(after)
        let removed = before.subtracting(after)
        guard !removed.isEmpty else { return result }
        let core = engine.core, workspace = SQLiteValue.text(version.workspaceId)
        func excluded(_ entity: VocabularyPersistenceEntity) throws -> String {
            let ids = rows.filter { $0.entity == entity }.map(\.id)
            guard let encoded = String(data: try JSONEncoder().encode(ids), encoding: .utf8) else {
                throw VocabularyError.invalidArchive
            }
            return encoded
        }
        let blocks = try excluded(.blocks)
        for reference in removed {
            let blockOwner = try core.scalarInt(sql: """
                SELECT EXISTS(SELECT 1 FROM notebook_blocks WHERE workspace_id=?
                  AND CASE WHEN json_valid(payload_json) THEN json_extract(payload_json,'$.content.image._0.digest') END=?
                  AND id NOT IN (SELECT value FROM json_each(?)))
                """, values: [workspace, .text(reference.digest), .text(blocks)]) != 0
            if !blockOwner { result.remove(reference) }

        }
        return result
    }
}
