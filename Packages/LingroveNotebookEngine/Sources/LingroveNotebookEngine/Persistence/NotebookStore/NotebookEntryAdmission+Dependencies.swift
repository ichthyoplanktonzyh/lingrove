import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec

extension NotebookEntryAdmission {
    /// A certified graph guarantees mapping evidence belongs to its own sense. Selecting
    /// this entry's patterns/mappings and their referenced node definitions is therefore a
    /// closed validation fragment. Nodes are borrowed, never retired with a lexical owner.
    func localRows(entryID: UUID, incoming: VocabularyEntry? = nil) throws -> [VocabularyPersistenceRow]? {
        var rows = try engine.notebookEntryRowsInTransaction(entryID: entryID.uuidString, workspace: version.workspaceId)
        let senses = Set(rows.filter { $0.entity == .senses }.compactMap { UUID(uuidString: $0.id) })
        func append(_ entity: VocabularyPersistenceEntity, column: String, ids: Set<UUID>) throws {
            guard !ids.isEmpty else { return }
            rows += try engine.readNotebookRows(entity, workspace: version.workspaceId,
                predicate: "\(column) IN (SELECT value FROM json_each(?))", arguments: [.text(try json(ids))])
        }
        for entity in [VocabularyPersistenceEntity.usagePatterns, .meaningMappings] {
            try append(entity, column: "parent_id", ids: senses)
        }
        let patterns = Set(rows.filter { $0.entity == .usagePatterns }.compactMap { UUID(uuidString: $0.id) })
        let mappings = rows.filter { $0.entity == .meaningMappings }
        let mappingIDs = Set(mappings.compactMap { UUID(uuidString: $0.id) })
        let nodes = Set(mappings.compactMap { $0.indexValue(.meaningID).flatMap(UUID.init(uuidString:)) })
        try append(.patternSlots, column: "parent_id", ids: patterns)
        for entity in [VocabularyPersistenceEntity.mappingRoles, .mappingEvidence] {
            try append(entity, column: "parent_id", ids: mappingIDs)
        }
        try append(.meaningNodes, column: "id", ids: nodes)
        for entity in [VocabularyPersistenceEntity.meaningLabels, .meaningRoles] {
            try append(entity, column: "parent_id", ids: nodes)
        }
        if let incoming {
            let ownedClaims = Set(rows.filter { $0.entity == .usages }.compactMap { UUID(uuidString: $0.id) })
            let extra = Set(incoming.examples.map(\.id)).subtracting(ownedClaims)
            let claims = try engine.readNotebookRows(.usages, workspace: version.workspaceId,
                predicate: "id IN (SELECT value FROM json_each(?))", arguments: [.text(try json(extra))])
            // A detached capture may accept an unresolved interpretation; an accepted claim
            // owned elsewhere needs the full capture policy's explicit identity cloning.
            guard claims.allSatisfy({ $0.indexValue(.status) == "candidate" && $0.indexValue(.senseID) == nil }) else { return nil }
            rows += claims
            try append(.usageExplanations, column: "parent_id", ids: Set(claims.compactMap { UUID(uuidString: $0.id) }))
            let ownedOccurrences = Set(rows.filter { $0.entity == .occurrences }.compactMap { UUID(uuidString: $0.id) })
            let occurrences = Set(incoming.examples.map { $0.occurrenceID ?? $0.id }).union(
                claims.compactMap { $0.indexValue(.occurrenceID).flatMap(UUID.init(uuidString:)) })
            try append(.occurrences, column: "id", ids: occurrences.subtracting(ownedOccurrences))
            let ownedSources = Set(rows.filter { $0.entity == .sources }.compactMap { UUID(uuidString: $0.id) })
            let sources = Set(incoming.examples.map(\.sourceID)).union(
                rows.filter { $0.entity == .occurrences }.compactMap { $0.parentID.flatMap(UUID.init(uuidString:)) })
            try append(.sources, column: "id", ids: sources.subtracting(ownedSources))
        }
        return rows
    }

    /// Different interpretations cannot claim the same occurrence for different entries.
    /// A local fragment can prove uniqueness inside itself; this indexed query proves the
    /// unchanged corpus still owns all other accepted occurrences.
    func checkOccurrenceOwners(_ entry: VocabularyEntry) throws {
        let occurrences = Set(entry.examples.map { $0.occurrenceID ?? $0.id })
        guard !occurrences.isEmpty else { return }
        guard try engine.core.scalarInt(sql: """
            SELECT EXISTS(SELECT 1 FROM notebook_usages u
              JOIN notebook_senses s ON s.workspace_id=u.workspace_id AND s.id=u.sense_id
              WHERE u.workspace_id=? AND u.occurrence_id IN (SELECT value FROM json_each(?))
                AND u.status='accepted' AND s.parent_id<>?)
            """, values: [.text(version.workspaceId), .text(try json(occurrences)), .text(entry.id.uuidString)]) == 0 else {
            throw VocabularyError.invalidArchive
        }
    }
}
