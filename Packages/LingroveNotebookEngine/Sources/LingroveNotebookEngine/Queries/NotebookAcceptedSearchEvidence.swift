import Foundation

extension LingroveNotebookEngine {
    /// The canonical scalar reader owns these short-lived joins inside its pinned read
    /// transaction. Scan each workspace's rows in physical order instead of interleaving
    /// random payload reads across three UUID indexes. Only accepted, fully joined uses enter
    /// search; rowids select read order and never become cached or durable identities.
    func appendAcceptedSearchEvidence(workspace: String, fields: inout [UUID: [Int]],
                                      texts: inout NotebookSearchTextTable.Builder) throws {
        struct Use { let sense: UUID; let meaning: String; let translation: String }
        var occurrences: [String: [Use]] = [:]
        _ = try core.query(sql: """
            SELECT sense_id,occurrence_id,json_extract(payload_json,'$.meaning'),json_extract(payload_json,'$.translation'),
                   CASE WHEN json_array_length(payload_json,'$.translationVariants')>0 THEN
                    (SELECT json_group_array(json_extract(value,'$.text')) FROM json_each(payload_json,'$.translationVariants')) END
            FROM notebook_usages WHERE rowid IN (SELECT rowid FROM notebook_usages WHERE workspace_id=?) AND status='accepted'
            """, values: [.text(workspace)]) { row -> Bool in
            try Task.checkCancellation()
            guard let sense = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)), fields[sense] != nil else { return false }
            if let variants = DatabaseCore.columnOptionalText(statement: row, index: 4) {
                for value in try core.decoder.decode([String?].self, from: Data(variants.utf8)).compactMap({ $0 }) where !value.isEmpty {
                    fields[sense, default: []].append(texts.intern(value))
                }
            }
            let key = DatabaseCore.columnText(statement: row, index: 1)
            occurrences[key, default: []].append(.init(sense: sense,
                meaning: DatabaseCore.columnOptionalText(statement: row, index: 2) ?? "",
                translation: DatabaseCore.columnOptionalText(statement: row, index: 3) ?? ""))
            return true
        }
        var sources: [String: [Use]] = [:]
        _ = try core.query(sql: """
            SELECT id,parent_id FROM notebook_occurrences
            WHERE rowid IN (SELECT rowid FROM notebook_occurrences WHERE workspace_id=?)
            """, values: [.text(workspace)]) { row -> Bool in
            try Task.checkCancellation()
            guard let uses = occurrences.removeValue(forKey: DatabaseCore.columnText(statement: row, index: 0)) else { return false }
            sources[DatabaseCore.columnText(statement: row, index: 1), default: []].append(contentsOf: uses)
            return true
        }
        occurrences.removeAll()
        guard !sources.isEmpty else { return }
        let sourceIDs = try core.encodeJsonString(value: Array(sources.keys))
        _ = try core.query(sql: """
            SELECT id,json_extract(payload_json,'$.text') FROM notebook_sources
            WHERE rowid IN (SELECT rowid FROM notebook_sources WHERE workspace_id=? AND id IN (SELECT value FROM json_each(?)))
            """, values: [.text(workspace), .text(sourceIDs)]) { row -> Bool in
            try Task.checkCancellation()
            guard let uses = sources.removeValue(forKey: DatabaseCore.columnText(statement: row, index: 0)) else { return false }
            let source = DatabaseCore.columnOptionalText(statement: row, index: 1) ?? ""
            for use in uses {
                for value in [use.meaning, use.translation, source] where !value.isEmpty {
                    fields[use.sense, default: []].append(texts.intern(value))
                }
            }
            return true
        }
    }
}
