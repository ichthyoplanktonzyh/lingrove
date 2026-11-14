import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec
import SQLite3

/// Browsing values are deliberately distinct from a document or a checked save state. A page
/// knows the global count, but owns only its summaries; it can never authorize a partial save.
/// The view constructs this filter value; the engine copies it into each continuation cursor.
public nonisolated struct NotebookBrowseQuery: Equatable, Sendable {
    public var language: LearningLanguage?
    public var tag: String
    public var newestFirst: Bool
    public init(language: LearningLanguage? = nil, tag: String = "", newestFirst: Bool = true) {
        self.language = language; self.tag = tag; self.newestFirst = newestFirst
    }
}

/// Revision alone is insufficient: raw SQL repairs also advance the durable corpus clock.
/// Cursors and detail responses carry this fence across actor/UI boundaries.
public nonisolated struct NotebookBrowseFence: Equatable, Sendable {
    public let version: LingroveNotebookVersion
    public let corpus: NotebookChangeToken
}

/// One page owns these display/selection fields. Keeping them separate prevents a sidebar
/// from fabricating complete entries whose missing examples or notes look like saved empties.
public nonisolated struct NotebookEntrySummary: Equatable, Identifiable, Sendable {
    /// A sidebar can name a destination without claiming to have loaded its full sense body.
    public struct Sense: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public let hasImage: Bool
    }
    public let id: UUID
    public let expression: String
    public let language: LearningLanguage?
    public let senses: [Sense]
}

/// Keyset pagination keeps later pages independent of the number of already displayed rows.
/// Its query and exact fence prevent mixing pages after a filter, account or corpus change.
public nonisolated struct NotebookBrowseCursor: Sendable {
    let fence: NotebookBrowseFence
    let query: NotebookBrowseQuery
    let createdAt: Double
    let id: String
    let total: Int
}

/// The worker returns one immutable batch. Its total covers the global query, while entries
/// contain only this batch; the UI retains the next cursor until it requests another page.
public nonisolated struct NotebookBrowsePage: Sendable {
    public let fence: NotebookBrowseFence
    public let entries: [NotebookEntrySummary]
    public let total: Int
    public let next: NotebookBrowseCursor?
    /// Returned entry/sense summary rows. These use SQL scalar extraction, without decoding
    /// entry/evidence payloads through JSONDecoder; SQL count/metadata rows are excluded.
    public let decodedRows: Int
}

/// The UI retains one complete entry and its local row proof for display/image reads. This
/// value never certifies unrelated entries or authorizes the engine's complete save path.
public nonisolated struct NotebookEntryDetail: Sendable {
    public let fence: NotebookBrowseFence
    public let entry: VocabularyEntry?
    public let decodedRows: Int
    public let mappedSenseIDs: Set<UUID>
}

/// An ephemeral SQL header, owned only by a single page transaction. Named fields keep the
/// display-order key separate from the visible summary and its stable domain identity.
private nonisolated struct NotebookBrowseHeader {
    let id: UUID
    let expression: String
    let language: LearningLanguage?
    let createdAt: Double
}

extension LingroveNotebookEngine {
    public func notebookBrowseFence() throws -> NotebookBrowseFence {
        try core.inReadTransaction { try browseFenceInTransaction() }
    }

    func browseFenceInTransaction() throws -> NotebookBrowseFence {
        guard let version = try currentNotebookVersionInTransaction() else { throw VocabularyError.editConflict }
        return try .init(version: version, corpus: core.notebookChangeStamp().corpus)
    }

    /// Reads headers for at most 100 entries. SQL performs the global count and filtering;
    /// examples, source text, rich explanations and graph rows never enter the page decoder.
    public func browseNotebook(_ query: NotebookBrowseQuery = .init(), after cursor: NotebookBrowseCursor? = nil,
                               limit: Int = 100) throws -> NotebookBrowsePage {
        guard (1...100).contains(limit) else { throw VocabularyError.invalidContent }
        return try core.inReadTransaction {
            try Task.checkCancellation()
            let fence = try browseFenceInTransaction()
            if let cursor, cursor.fence != fence || cursor.query != query { throw VocabularyError.editConflict }
            let workspace = fence.version.workspaceId
            let indexedTags = try query.tag.isEmpty ? false : NotebookTagIndex.available(in: core, workspace: workspace)
            var filter = """
                e.workspace_id=? AND EXISTS (SELECT 1 FROM notebook_senses saved
                 WHERE saved.workspace_id=e.workspace_id AND saved.parent_id=e.id)
                """
            var values: [SQLiteValue] = [.text(workspace)]
            if let language = query.language { filter += " AND e.language=?"; values.append(.text(language.rawValue)) }
            if !query.tag.isEmpty {
                // Build the matching sense IDs once, then use canonical ID/parent indexes.
                // A correlated json_each per headword repeatedly opens collection rows and
                // can turn a selective tag into tens of thousands of random payload reads.
                let taggedSenses = indexedTags ? """
                    SELECT sense_id FROM notebook_collection_tags WHERE workspace_id=? AND tag=?
                    """ : """
                    SELECT c.sense_id FROM notebook_collections c,json_each(c.payload_json,'$.tags') tag
                    WHERE c.workspace_id=? AND tag.value=?
                    """
                filter += """
                 AND e.id IN (SELECT s.parent_id FROM notebook_senses s
                  WHERE s.workspace_id=? AND s.id IN (
                   \(taggedSenses)))
                """
                values += [.text(workspace), .text(workspace), .text(query.tag)]
            }
            let total = try cursor?.total ?? core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_entries e WHERE \(filter)", values: values)
            if let cursor {
                filter += """
                     AND (json_extract(e.payload_json,'$.createdAt') \(query.newestFirst ? "<" : ">") ?
                     OR (json_extract(e.payload_json,'$.createdAt')=? AND e.id>?))
                    """
                values += [.real(cursor.createdAt), .real(cursor.createdAt), .text(cursor.id)]
            }
            // Materialize the tagged owners before sorting. Otherwise SQLite can choose the
            // newest-first workspace index and walk every untagged headword to satisfy LIMIT.
            let headerSQL = query.tag.isEmpty ? """
                SELECT e.id,e.expression,e.language,json_extract(e.payload_json,'$.createdAt')
                FROM notebook_entries e WHERE \(filter)
                ORDER BY json_extract(e.payload_json,'$.createdAt') \(query.newestFirst ? "DESC" : "ASC"),e.id ASC LIMIT ?
                """ : """
                WITH matched AS MATERIALIZED (
                    SELECT e.id,e.expression,e.language,json_extract(e.payload_json,'$.createdAt') created_at
                    FROM notebook_entries e WHERE \(filter))
                SELECT id,expression,language,created_at FROM matched
                ORDER BY created_at \(query.newestFirst ? "DESC" : "ASC"),id ASC LIMIT ?
                """
            let headers = try core.query(sql: headerSQL, values: values + [.integer(Int64(limit + 1))]) { row -> NotebookBrowseHeader in
                guard let id = UUID(uuidString: try Self.browseText(row, 0)),
                      [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 3)) else { throw VocabularyError.invalidArchive }
                let rawLanguage = try Self.browseText(row, 2)
                let language = LearningLanguage(rawValue: rawLanguage)
                guard rawLanguage == "und" || language != nil else { throw VocabularyError.invalidArchive }
                return .init(id: id, expression: try Self.browseText(row, 1), language: language,
                    createdAt: sqlite3_column_double(row, 3))
            }
            var decoded = 0
            let summaries = try headers.prefix(limit).map { header in
                var senseValues: [SQLiteValue] = [.text(workspace), .text(header.id.uuidString)]
                var senseFilter = "s.workspace_id=? AND s.parent_id=?"
                if !query.tag.isEmpty {
                    senseFilter += indexedTags ? """
                         AND EXISTS (SELECT 1 FROM notebook_collection_tags tag
                         WHERE tag.workspace_id=s.workspace_id AND tag.tag=? AND tag.sense_id=s.id)
                        """ : """
                         AND EXISTS (SELECT 1 FROM notebook_collections c,json_each(c.payload_json,'$.tags') tag
                         WHERE c.workspace_id=s.workspace_id AND c.sense_id=s.id AND tag.value=?)
                        """
                    senseValues.append(.text(query.tag))
                }
                let senses = try core.query(sql: """
                    SELECT s.id,COALESCE(NULLIF(s.meaning,''),
                        (SELECT json_extract(b.payload_json,'$.content.text._0.text')
                         FROM notebook_collections c JOIN notebook_blocks b ON b.workspace_id=c.workspace_id AND b.parent_id=c.id
                         WHERE c.workspace_id=s.workspace_id AND c.sense_id=s.id
                           AND trim(json_extract(b.payload_json,'$.content.text._0.text'))!=''
                         ORDER BY b.position LIMIT 1),''),
                        CASE WHEN s.meaning='' THEN EXISTS (
                         SELECT 1 FROM notebook_collections c JOIN notebook_blocks b ON b.workspace_id=c.workspace_id AND b.parent_id=c.id
                         WHERE c.workspace_id=s.workspace_id AND c.sense_id=s.id AND json_type(b.payload_json,'$.content.image')='object')
                         ELSE 0 END
                    FROM notebook_senses s WHERE \(senseFilter)
                    ORDER BY json_extract(s.payload_json,'$.createdAt'),s.id
                    """, values: senseValues) { row -> NotebookEntrySummary.Sense in
                    guard let id = UUID(uuidString: try Self.browseText(row, 0)) else { throw VocabularyError.invalidArchive }
                    return .init(id: id, title: try Self.browseText(row, 1), hasImage: sqlite3_column_int(row, 2) == 1)
                }
                decoded += 1 + senses.count
                return NotebookEntrySummary(id: header.id, expression: header.expression, language: header.language, senses: senses)
            }
            let last = headers.prefix(limit).last
            let next = headers.count > limit ? last.map { NotebookBrowseCursor(fence: fence, query: query,
                createdAt: $0.createdAt, id: $0.id.uuidString, total: total) } : nil
            try Task.checkCancellation()
            return .init(fence: fence, entries: summaries, total: total, next: next, decodedRows: decoded)
        }
    }

    /// This entry's complete evidence subtree is decoded with the same lossless codec used by
    /// full loads. The temporary document is local to this read and grants no global save proof.
    /// Global relationships/identifier validation still belongs to the transaction writer.
    public func notebookEntryDetail(entryID: UUID? = nil, senseID: UUID? = nil, lookupKey: String? = nil,
                                    expected: NotebookBrowseFence? = nil) throws -> NotebookEntryDetail {
        try core.inReadTransaction {
            try Task.checkCancellation()
            let fence = try browseFenceInTransaction()
            if let expected, expected != fence { throw VocabularyError.editConflict }
            let workspace = fence.version.workspaceId
            let id: String?
            if let entryID { id = entryID.uuidString } else if let senseID {
                let direct = try core.query(sql: "SELECT parent_id FROM notebook_senses WHERE workspace_id=? AND id=?",
                    values: [.text(workspace), .text(senseID.uuidString)]) { try Self.browseText($0, 0) }.first
                // Alias lookup is a fallback for old links, never the ordinary indexed path.
                id = try direct ?? core.query(sql: """
                    SELECT s.parent_id FROM notebook_senses s,json_each(s.payload_json,'$.mergedFrom') alias
                    WHERE s.workspace_id=? AND alias.value=? LIMIT 1
                    """, values: [.text(workspace), .text(senseID.uuidString)]) { try Self.browseText($0, 0) }.first
            } else if let lookupKey {
                id = try core.query(sql: "SELECT id FROM notebook_entries WHERE workspace_id=? AND lookup_key=?",
                    values: [.text(workspace), .text(lookupKey)]) { try Self.browseText($0, 0) }.first
            } else { throw VocabularyError.invalidContent }
            guard let id else { return .init(fence: fence, entry: nil, decodedRows: 0, mappedSenseIDs: []) }
            let rows = try notebookEntryRowsInTransaction(entryID: id, workspace: workspace)
            guard !rows.isEmpty else { return .init(fence: fence, entry: nil, decodedRows: 0, mappedSenseIDs: []) }
            let senses = "SELECT id FROM notebook_senses WHERE workspace_id=? AND parent_id=?"
            let base: [SQLiteValue] = [.text(workspace), .text(id)]
            let document = try VocabularyPersistenceCodec.decode(.init(rows: rows))
            let entries = document.entries
            guard entries.count == 1, let entry = entries.first, entry.id.uuidString == id else { throw VocabularyError.invalidArchive }
            try Task.checkCancellation()
            let mapped = try core.query(sql: """
                SELECT DISTINCT parent_id FROM notebook_meaning_mappings
                WHERE workspace_id=? AND parent_id IN (\(senses)) AND json_extract(payload_json,'$.provenance.status')='confirmed'
                """, values: [.text(workspace)] + base) { row -> UUID in
                guard let id = UUID(uuidString: try Self.browseText(row, 0)) else { throw VocabularyError.invalidArchive }
                return id
            }
            return .init(fence: fence, entry: entry, decodedRows: rows.count, mappedSenseIDs: Set(mapped))
        }
    }

    /// Detail reads retain a narrow reference proof, not a full save proof. Recheck its exact
    /// corpus fence and workspace's blob mapping together before returning any image bytes.
    public func notebookEntryImage(_ reference: VocabularyImageReference, detail: NotebookEntryDetail) throws -> Data {
        try core.inReadTransaction {
            guard try browseFenceInTransaction() == detail.fence, let entry = detail.entry else {
                throw VocabularyError.editConflict
            }
            guard VocabularyDocumentValidation.imageReferences(.init(entries: [entry])).contains(reference) else {
                throw VocabularyError.invalidContent
            }
            return try LingroveNotebookMediaStore(core: core).ownedImage(reference, workspaceId: detail.fence.version.workspaceId)
        }
    }

    /// Filter metadata is requested separately, so opening the first page never scans tags.
    public func notebookBrowseTags(expected: NotebookBrowseFence) throws -> [String] {
        try core.inReadTransaction {
            guard try browseFenceInTransaction() == expected else { throw VocabularyError.editConflict }
            let indexed = try NotebookTagIndex.available(in: core, workspace: expected.version.workspaceId)
            return try core.query(sql: indexed ? """
                SELECT DISTINCT tag FROM notebook_collection_tags WHERE workspace_id=? ORDER BY tag
                """ : """
                SELECT DISTINCT tag.value FROM notebook_collections c,json_each(c.payload_json,'$.tags') tag
                WHERE c.workspace_id=? ORDER BY tag.value
                """, values: [.text(expected.version.workspaceId)]) { try Self.browseText($0, 0) }
        }
    }

    /// A caller-owned SQL transaction selects the complete lexical/evidence subtree. Both
    /// detail readers and admitted local writers use this same lossless row selection.
    func notebookEntryRowsInTransaction(entryID id: String, workspace: String) throws -> [VocabularyPersistenceRow] {
        let senses = "SELECT id FROM notebook_senses WHERE workspace_id=? AND parent_id=?"
        let collections = "SELECT id FROM notebook_collections WHERE workspace_id=? AND sense_id IN (\(senses))"
        let usages = "SELECT id FROM notebook_usages WHERE workspace_id=? AND sense_id IN (\(senses))"
        let occurrences = "SELECT occurrence_id FROM notebook_usages WHERE workspace_id=? AND sense_id IN (\(senses))"
        let base: [SQLiteValue] = [.text(workspace), .text(id)]
        var rows: [VocabularyPersistenceRow] = []
        func append(_ entity: VocabularyPersistenceEntity, _ predicate: String, _ arguments: [SQLiteValue]) throws {
            rows += try readNotebookRows(entity, workspace: workspace, predicate: predicate, arguments: arguments)
        }
        try append(.entries, "id=?", [.text(id)])
        if rows.isEmpty { return [] }
        try append(.senses, "parent_id=?", [.text(id)])
        try append(.senseExplanations, "parent_id IN (\(senses))", base)
        try append(.collections, "sense_id IN (\(senses))", base)
        for entity in [VocabularyPersistenceEntity.blocks, .collectionInterpretations] {
            try append(entity, "parent_id IN (\(collections))", [.text(workspace)] + base)
        }
        try append(.usages, "sense_id IN (\(senses))", base)
        try append(.usageExplanations, "parent_id IN (\(usages))", [.text(workspace)] + base)
        try append(.occurrences, "id IN (\(occurrences))", [.text(workspace)] + base)
        try append(.sources, "id IN (SELECT parent_id FROM notebook_occurrences WHERE workspace_id=? AND id IN (\(occurrences)))",
            [.text(workspace), .text(workspace)] + base)
        return rows
    }

    func readNotebookRows(_ entity: VocabularyPersistenceEntity, workspace: String, predicate: String,
                            arguments: [SQLiteValue]) throws -> [VocabularyPersistenceRow] {
        let columns = ["id", "parent_id", "position", "payload_json"] + entity.indexKeys.map(\.rawValue)
        // The codec orders this tiny subtree by identity/explicit authored position. Asking
        // SQL to order by id instead can make SQLite choose a workspace-wide primary-key
        // walk to avoid sorting, discarding the selective parent index despite a tiny result.
        return try core.query(sql: """
            SELECT \(columns.joined(separator: ",")) FROM \(LingroveNotebookSchema.table(entity))
            WHERE workspace_id=? AND \(predicate)
            """,
            values: [.text(workspace)] + arguments) { row in
            let position = sqlite3_column_int64(row, 2)
            guard sqlite3_column_type(row, 2) == SQLITE_INTEGER, position >= 0 else { throw VocabularyError.invalidArchive }
            let indexes = try Dictionary(uniqueKeysWithValues: entity.indexKeys.enumerated().map { offset, key in
                (key, sqlite3_column_type(row, Int32(offset + 4)) == SQLITE_NULL ? nil : try Self.browseText(row, Int32(offset + 4)))
            })
            return try .init(entity: entity, id: Self.browseText(row, 0),
                parentID: sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : Self.browseText(row, 1),
                position: Int(position), payload: Data(Self.browseText(row, 3).utf8), indexValues: indexes)
        }
    }

    private static func browseText(_ row: OpaquePointer, _ index: Int32) throws -> String {
        guard sqlite3_column_type(row, index) == SQLITE_TEXT, let bytes = sqlite3_column_text(row, index),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, index))),
                encoding: .utf8) else {
            throw VocabularyError.invalidArchive
        }
        return value
    }
}
