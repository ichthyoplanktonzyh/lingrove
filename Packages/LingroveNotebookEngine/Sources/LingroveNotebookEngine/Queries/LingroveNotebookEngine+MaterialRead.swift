import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec

/// A read result owns complete requested records and their exact fence, not a complete corpus
/// or a save proof. CLI and other hosts can return these values without loading unrelated data.
public nonisolated struct NotebookMaterialRead: Sendable {
    public let fence: NotebookBrowseFence
    public let entries: [VocabularyEntry]
    public let values: [NotebookToolJSON]
    public let categoryMemberships: [NotebookToolJSON]
}

extension LingroveNotebookEngine {
    /// Resolve all requested IDs under one SQLite snapshot, preserving caller order and
    /// rejecting a missing ID rather than returning a partial successful batch.
    public func readNotebookMaterial(ids: [UUID], selectingSenses: Bool = false,
                                     includeClassification: Bool = false) throws -> NotebookMaterialRead {
        let maximum = selectingSenses ? NotebookCaptureContract.maximumSenses : 100
        guard (1...maximum).contains(ids.count), Set(ids).count == ids.count else { throw VocabularyError.invalidContent }
        return try core.inReadTransaction {
            let fence = try browseFenceInTransaction(), version = fence.version
            let encoded = String(decoding: try core.encoder.encode(ids.map(\.uuidString)), as: UTF8.self)
            let owners: [UUID: UUID]
            if selectingSenses {
                let rows = try core.query(sql: """
                    SELECT id,parent_id FROM notebook_senses WHERE workspace_id=?
                      AND id IN (SELECT value FROM json_each(?))
                    """, values: [.text(version.workspaceId), .text(encoded)]) { row -> (UUID, UUID) in
                    guard let sense = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)),
                          let entry = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 1)) else {
                        throw VocabularyError.invalidArchive
                    }
                    return (sense, entry)
                }
                owners = Dictionary(uniqueKeysWithValues: rows)
            } else { owners = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) }) }
            guard ids.allSatisfy({ owners[$0] != nil }) else { throw NotebookToolError(code: .notFound, message: "Sense not found.") }
            var selectedRows: [VocabularyPersistenceRow.Key: VocabularyPersistenceRow] = [:]
            let admission = NotebookEntryAdmission(engine: self, version: version)
            for owner in Set(owners.values) {
                try Task.checkCancellation()
                guard let rows = try admission.localRows(entryID: owner), !rows.isEmpty else {
                    throw NotebookToolError(code: .notFound, message: "Entry not found.")
                }
                for row in rows { selectedRows[row.key] = row }
            }
            // The row codec proves this closed lexical/evidence fragment is lossless. It stays
            // inside this read; callers receive a projection rather than a partial notebook.
            let fragment = try VocabularyPersistenceCodec.decode(.init(rows: Array(selectedRows.values)))
            let indexed = Dictionary(uniqueKeysWithValues: fragment.entries.map { ($0.id, $0) })
            let entries = try ids.map { id -> VocabularyEntry in
                guard let owner = owners[id], var entry = indexed[owner] else {
                    throw NotebookToolError(code: .notFound, message: "Entry not found.")
                }
                if selectingSenses { entry.senses.removeAll { $0.id != id } }
                return entry
            }
            let selected = Set(entries.flatMap(\.senses).map(\.id))
            let projection = NotebookSenseProjection(fragment, selecting: selected)
            let values = try zip(ids, entries).map { id, entry in
                try selectingSenses ? projection.sense(id, in: entry) : projection.entry(entry)
            }
            let memberships = try includeClassification ? materialMemberships(fragment: fragment,
                senseIDs: selected, workspace: version.workspaceId) : []
            return .init(fence: fence, entries: entries, values: values, categoryMemberships: memberships)
        }
    }

    /// Metadata counts do not decode text, examples, media or the semantic graph.
    public func notebookCorpusCounts() throws -> (version: LingroveNotebookVersion, counts: [String: Int]) {
        try core.inReadTransaction {
            guard let version = try currentNotebookVersionInTransaction() else { throw VocabularyError.editConflict }
            // A loaded notebook already owns these counts. Reuse it only after checking
            // the header and durable corpus clock; cold/stale reads count SQL rows without
            // decoding the graph or manufacturing a complete writer baseline.
            if let cached = core.notebookSaveCache, LingroveNotebookVersion(cached.snapshot) == version,
               try core.notebookCacheToken() == cached.token {
                let document = cached.snapshot.document
                return (version, ["entryCount": document.catalog.count, "senseCount": cached.state.entries.reduce(0) { $0 + $1.senses.count },
                    "sourceCount": document.sources.count, "occurrenceCount": document.occurrences.count,
                    "interpretationCount": document.interpretations.count])
            }
            var counts: [String: Int] = [:]
            for (name, table) in [("entryCount", "entries"), ("senseCount", "senses"), ("sourceCount", "sources"),
                                  ("occurrenceCount", "occurrences"), ("interpretationCount", "usages")] {
                counts[name] = try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_\(table) WHERE workspace_id=?",
                    values: [.text(version.workspaceId)])
            }
            return (version, counts)
        }
    }

    private func materialMemberships(fragment: VocabularyDocument, senseIDs: Set<UUID>, workspace: String) throws -> [NotebookToolJSON] {
        let nodes = Set(fragment.semantics.mappings.filter { senseIDs.contains($0.senseID) }.map(\.nodeID))
        guard !nodes.isEmpty else { return [] }
        let encoded = String(decoding: try core.encoder.encode(nodes.map(\.uuidString)), as: UTF8.self)
        let rows = try readNotebookRows(.categoryMemberships, workspace: workspace,
            predicate: "meaning_id IN (SELECT value FROM json_each(?))", arguments: [.text(encoded)])
        let memberships = try rows.map { try core.decoder.decode(VocabularyMeaningCategoryMembership.self, from: $0.encodedPayload()) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let categories = String(decoding: try core.encoder.encode(Set(memberships.map(\.categoryID)).map(\.uuidString)), as: UTF8.self)
        let keys = try core.query(sql: """
            SELECT id,json_extract(payload_json,'$.key') FROM notebook_categories WHERE workspace_id=?
              AND id IN (SELECT value FROM json_each(?))
            """, values: [.text(workspace), .text(categories)]) { row -> (String, String?) in
            (DatabaseCore.columnText(statement: row, index: 0), DatabaseCore.columnOptionalText(statement: row, index: 1))
        }
        let indexed = Dictionary(uniqueKeysWithValues: keys)
        return memberships.map { item in
            .object(["id": .string(item.id.uuidString), "nodeID": .string(item.nodeID.uuidString),
                "categoryID": .string(item.categoryID.uuidString),
                "key": indexed[item.categoryID.uuidString].flatMap { $0 }.map(NotebookToolJSON.string) ?? .null])
        }
    }
}

/// Batch planning receives only existing lexical owners under one exact read fence. Missing
/// keys represent new entries; no caller-supplied key list grants complete save authority.
public nonisolated struct NotebookEntryLookup: Sendable {
    public let fence: NotebookBrowseFence
    public let entries: [VocabularyEntry]
}

extension LingroveNotebookEngine {
    public func notebookEntries(lookupKeys: Set<String>, expected: LingroveNotebookVersion) throws -> NotebookEntryLookup {
        guard lookupKeys.count <= 100 else { throw VocabularyError.invalidContent }
        return try core.inReadTransaction {
            try Task.checkCancellation()
            let fence = try browseFenceInTransaction()
            guard fence.version == expected else { throw VocabularyError.editConflict }
            let keys = String(decoding: try core.encoder.encode(lookupKeys.sorted()), as: UTF8.self)
            // ORDER BY id can make SQLite scan the workspace primary key instead of the
            // selective lookup-key index. Sort only the at-most-100 matched owners here.
            let ids = try core.query(sql: "SELECT id FROM notebook_entries WHERE workspace_id=? AND lookup_key IN (SELECT value FROM json_each(?))",
                values: [.text(expected.workspaceId), .text(keys)]) { DatabaseCore.columnText(statement: $0, index: 0) }.sorted()
            let entries = try ids.flatMap { id -> [VocabularyEntry] in
                try Task.checkCancellation()
                let rows = try notebookEntryRowsInTransaction(entryID: id, workspace: expected.workspaceId)
                return try VocabularyPersistenceCodec.decode(.init(rows: rows)).entries
            }
            return .init(fence: fence, entries: entries)
        }
    }
}
