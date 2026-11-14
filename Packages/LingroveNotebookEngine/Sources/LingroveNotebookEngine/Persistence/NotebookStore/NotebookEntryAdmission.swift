import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec

/// One writer transaction borrows this SQL admission helper. It checks the global facts that
/// a detached entry fragment cannot prove: identity/key ownership, external evidence reuse,
/// accepted occurrence ownership and shared evidence. Missing proof uses the full path.
struct NotebookEntryAdmission {
    let engine: LingroveNotebookEngine
    let version: LingroveNotebookVersion
    private var core: DatabaseCore { engine.core }

    func json(_ ids: Set<UUID>) throws -> String {
        let data = try JSONEncoder().encode(ids.map(\.uuidString).sorted())
        guard let text = String(data: data, encoding: .utf8) else { throw VocabularyError.invalidArchive }
        return text
    }

    /// Existing evidence outside this fragment may require cloning/reconciling its source or
    /// unresolved interpretation. The ordinary full command owns that broader operation.
    func hasExternalEvidence(_ entry: VocabularyEntry, rows: [VocabularyPersistenceRow]) throws -> Bool {
        let families: [(VocabularyPersistenceEntity, Set<UUID>)] = [
            (.sources, Set(entry.examples.map(\.sourceID))),
            (.occurrences, Set(entry.examples.map { $0.occurrenceID ?? $0.id })),
            (.usages, Set(entry.examples.map(\.id)))
        ]
        for (entity, ids) in families {
            let owned = Set(rows.filter { $0.entity == entity }.compactMap { UUID(uuidString: $0.id) })
            let candidates = ids.subtracting(owned)
            if !candidates.isEmpty, try core.scalarInt(sql: """
                SELECT EXISTS(SELECT 1 FROM \(LingroveNotebookSchema.table(entity)) WHERE workspace_id=?
                    AND id IN (SELECT value FROM json_each(?)))
                """, values: [.text(version.workspaceId), .text(try json(candidates))]) != 0 { return true }
        }
        return false
    }

    func checkIdentities(_ entry: VocabularyEntry, previous: VocabularyEntry?) throws {
        let old = try previous.map(VocabularyDocumentValidation.identifiers(in:)) ?? []
        let added = try VocabularyDocumentValidation.identifiers(in: entry).subtracting(old)
        let workspace = SQLiteValue.text(version.workspaceId), owner = SQLiteValue.text(entry.id.uuidString)
        guard try core.scalarInt(sql: """
            SELECT EXISTS(SELECT 1 FROM notebook_entries WHERE workspace_id=? AND lookup_key=? AND id<>?)
            """, values: [workspace, .text(VocabularyIdentityPolicy.entryKey(entry)), owner]) == 0 else {
            throw VocabularyError.invalidArchive
        }
        if !added.isEmpty {
            let ids = "SELECT value FROM json_each(?)"
            let encoded = SQLiteValue.text(try json(added))
            let tests: [(String, [SQLiteValue])] = [
                ("SELECT 1 FROM notebook_entries WHERE workspace_id=? AND id IN (\(ids)) AND id<>?", [workspace, encoded, owner]),
                ("SELECT 1 FROM notebook_senses WHERE workspace_id=? AND id IN (\(ids)) AND parent_id<>?", [workspace, encoded, owner]),
                ("""
                 SELECT 1 FROM notebook_senses s,json_each(s.payload_json,'$.mergedFrom') alias
                 WHERE s.workspace_id=?
                   AND CASE WHEN json_valid(s.payload_json) THEN json_array_length(s.payload_json,'$.mergedFrom') ELSE 0 END>0
                   AND alias.value IN (\(ids)) AND s.parent_id<>?
                 """, [workspace, encoded, owner]),
                ("""
                 SELECT 1 FROM notebook_usages u JOIN notebook_senses s ON s.workspace_id=u.workspace_id AND s.id=u.sense_id
                 WHERE u.workspace_id=? AND u.id IN (\(ids)) AND u.status='accepted' AND s.parent_id<>?
                 """, [workspace, encoded, owner]),
                ("""
                 SELECT 1 FROM notebook_blocks b JOIN notebook_collections c ON c.workspace_id=b.workspace_id AND c.id=b.parent_id
                 JOIN notebook_senses s ON s.workspace_id=c.workspace_id AND s.id=c.sense_id
                 WHERE b.workspace_id=? AND b.id IN (\(ids)) AND s.parent_id<>?
                 """, [workspace, encoded, owner])
            ]
            for (sql, values) in tests {
                guard try core.scalarInt(sql: "SELECT EXISTS(\(sql))", values: values) == 0 else { throw VocabularyError.invalidArchive }
            }
        }
        let oldLexical = Set(previous.map { [$0.id] + $0.senses.map(\.id) + $0.examples.map(\.id) } ?? [])
        let lexical = Set([entry.id] + entry.senses.map(\.id) + entry.examples.map(\.id)).subtracting(oldLexical)
        if !lexical.isEmpty {
            let families: [VocabularyPersistenceEntity] = [.meaningNodes, .meaningLabels, .meaningRoles, .usagePatterns,
                .patternSlots, .meaningMappings, .mappingRoles, .meaningRelations, .retrievalCues, .cueTargets]
            for entity in families {
                guard try core.scalarInt(sql: """
                    SELECT EXISTS(SELECT 1 FROM \(LingroveNotebookSchema.table(entity)) WHERE workspace_id=?
                        AND id IN (SELECT value FROM json_each(?)))
                    """, values: [workspace, .text(try json(lexical))]) == 0 else { throw VocabularyError.invalidArchive }
            }
        }
    }

}
