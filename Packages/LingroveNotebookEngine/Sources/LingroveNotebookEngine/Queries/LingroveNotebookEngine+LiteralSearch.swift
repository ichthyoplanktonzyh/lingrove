import Foundation
import LingroveNotebook
import SQLite3

/// A browser actor owns this disposable retrieval material. It contains searchable strings,
/// summary destinations and confirmed joins, never a document, image bytes or writer proof.
/// Reuse requires the exact corpus fence and locale; raw writes invalidate it as revisions do.
public nonisolated struct NotebookLiteralSearchMaterial: Sendable {
    public enum Preparation: Sendable, Equatable { case canonical, persisted, incremental, memory }
    public internal(set) var preparation: Preparation = .canonical
    var entryDates: [UUID: Double] = [:]
    struct Mapping: Sendable, Codable { let sense: UUID; let node: UUID; let text: Int }
    struct Link: Sendable, Codable { let text: Int; let target: UUID }
    let texts: NotebookSearchTextTable
    let headers: [NotebookEntrySummary]
    let fields: [UUID: [Int]]
    let nodes: [UUID: [Int]]
    let mappings: [Mapping]
    let cues: [Link]
    let patterns: [Link]
    public let fence: NotebookBrowseFence
    public let locale: String

    public func results(matching query: String) throws -> NotebookSearchResults {
        try Task.checkCancellation()
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if phrase.isEmpty { return .init(fence: fence, entries: headers) }
        let terms = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        var matcher = NotebookSearchTextTable.Matcher(table: texts, term: phrase, locale: locale)
        func matching(_ candidates: Set<UUID>, using matcher: inout NotebookSearchTextTable.Matcher) throws -> Set<UUID> {
            var matches = Set<UUID>()
            for sense in candidates {
                try Task.checkCancellation()
                if fields[sense]?.contains(where: { matcher.contains($0) }) == true { matches.insert(sense) }
            }
            return matches
        }
        var direct = Set(fields.keys)
        for term in terms {
            if term == phrase { direct = try matching(direct, using: &matcher) }
            else {
                var termMatcher = NotebookSearchTextTable.Matcher(table: texts, term: term, locale: locale)
                direct = try matching(direct, using: &termMatcher)
            }
            if direct.isEmpty { break }
        }
        var matchedNodes = Set<UUID>()
        for (id, values) in nodes {
            try Task.checkCancellation()
            if values.contains(where: { matcher.contains($0) }) { matchedNodes.insert(id) }
        }
        for link in cues {
            let (text, node) = (link.text, link.target)
            try Task.checkCancellation()
            if matcher.contains(text) { matchedNodes.insert(node) }
        }
        var patternSenses = Set<UUID>()
        for link in patterns {
            let (text, sense) = (link.text, link.target)
            try Task.checkCancellation()
            if matcher.contains(text) { patternSenses.insert(sense) }
        }
        for mapping in mappings {
            try Task.checkCancellation()
            if direct.contains(mapping.sense) || patternSenses.contains(mapping.sense) || matcher.contains(mapping.text) {
                matchedNodes.insert(mapping.node)
            }
        }
        let linked = Set(mappings.filter { matchedNodes.contains($0.node) }.map(\.sense))
        let entries = try headers.compactMap { entry -> NotebookEntrySummary? in
            try Task.checkCancellation()
            let own = entry.senses.filter { direct.contains($0.id) }
            let senses = own.isEmpty ? entry.senses.filter { linked.contains($0.id) } : own
            return senses.isEmpty ? nil : .init(id: entry.id, expression: entry.expression, language: entry.language, senses: senses)
        }
        return .init(fence: fence, entries: entries)
    }
}

/// Query results retain summary identities only. A caller pages this frozen match set without
/// rescanning every field as the user scrolls; the composition owner still checks its fence.
public nonisolated struct NotebookSearchResults: Sendable {
    public let fence: NotebookBrowseFence
    public let entries: [NotebookEntrySummary]
    public func page(offset: Int = 0, limit: Int = 100) throws -> NotebookSearchPage {
        guard offset >= 0, offset <= entries.count, (1...100).contains(limit) else { throw VocabularyError.invalidContent }
        let end = min(entries.count, offset + limit)
        return .init(fence: fence, entries: Array(entries[offset..<end]), total: entries.count,
            nextOffset: end < entries.count ? end : nil)
    }
}
public nonisolated struct NotebookSearchPage: Sendable {
    public let fence: NotebookBrowseFence
    public let entries: [NotebookEntrySummary]
    public let total: Int
    public let nextOffset: Int?
}

extension LingroveNotebookEngine {
    /// Scalar retrieval projections avoid decoding/re-encoding the complete corpus, sources,
    /// occurrence ranges, directory and semantic graph. SQL joins accepted evidence exactly as
    /// VocabularyNotebookProjection does. Canonical persistence remains the sole authority.
    public func notebookLiteralSearchMaterial(locale: String = Locale.current.identifier) throws -> NotebookLiteralSearchMaterial {
        try core.inReadTransaction {
            try Task.checkCancellation()
            let fence = try browseFenceInTransaction(), workspace = fence.version.workspaceId
            var texts = NotebookSearchTextTable.Builder()
            var fields: [UUID: [Int]] = [:]
            var dates: [UUID: Double] = [:]
            var headerOrder: [UUID] = [], headers: [UUID: NotebookEntrySummary] = [:]
            let rows = try core.query(sql: """
                SELECT e.id,e.expression,e.language,json_extract(e.payload_json,'$.dictionaryForm'),
                       s.id,s.meaning,
                       CASE WHEN s.meaning='' THEN COALESCE((SELECT json_extract(b.payload_json,'$.content.text._0.text')
                        FROM notebook_collections c JOIN notebook_blocks b ON b.workspace_id=c.workspace_id AND b.parent_id=c.id
                        WHERE c.workspace_id=s.workspace_id AND c.sense_id=s.id AND json_type(b.payload_json,'$.content.text')='object'
                        ORDER BY b.position LIMIT 1),'') ELSE '' END,
                       CASE WHEN s.meaning='' THEN EXISTS(SELECT 1 FROM notebook_collections c JOIN notebook_blocks b
                        ON b.workspace_id=c.workspace_id AND b.parent_id=c.id WHERE c.workspace_id=s.workspace_id AND c.sense_id=s.id
                        AND json_type(b.payload_json,'$.content.image')='object') ELSE 0 END,json_extract(e.payload_json,'$.createdAt')
                FROM notebook_entries e JOIN notebook_senses s ON s.workspace_id=e.workspace_id AND s.parent_id=e.id
                WHERE e.workspace_id=?
                ORDER BY json_extract(e.payload_json,'$.createdAt') DESC,e.id,json_extract(s.payload_json,'$.createdAt'),s.id
                """, values: [.text(workspace)]) { row -> (UUID, String, LearningLanguage?, String, NotebookEntrySummary.Sense, Double) in
                try Task.checkCancellation()
                guard let entry = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)),
                      let sense = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 4)) else { throw VocabularyError.invalidArchive }
                let meaning = DatabaseCore.columnText(statement: row, index: 5)
                return (entry, DatabaseCore.columnText(statement: row, index: 1),
                    LearningLanguage(rawValue: DatabaseCore.columnText(statement: row, index: 2)),
                    DatabaseCore.columnOptionalText(statement: row, index: 3) ?? "",
                    .init(id: sense, title: meaning.isEmpty ? DatabaseCore.columnText(statement: row, index: 6) : meaning,
                        hasImage: sqlite3_column_int(row, 7) != 0), sqlite3_column_double(row, 8))
            }
            for (id, expression, language, dictionary, sense, date) in rows {
                dates[id] = date
                if let prior = headers[id] {
                    headers[id] = .init(id: id, expression: expression, language: language, senses: prior.senses + [sense])
                } else { headerOrder.append(id); headers[id] = .init(id: id, expression: expression, language: language, senses: [sense]) }
                fields[sense.id] = [expression, dictionary, sense.title].map { texts.intern($0) }
            }
            func append(_ sql: String, columns: Int) throws {
                _ = try core.query(sql: sql, values: [.text(workspace)]) { row -> Bool in
                    try Task.checkCancellation()
                    guard let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)), fields[id] != nil else { return false }
                    for column in 1...columns {
                        if let text = DatabaseCore.columnOptionalText(statement: row, index: Int32(column)), !text.isEmpty {
                            fields[id, default: []].append(texts.intern(text))
                        }
                    }
                    return true
                }
            }
            for path in ["standaloneMeanings", "alternateMeanings"] {
                try append("SELECT s.id,json_extract(v.value,'$.text') FROM notebook_senses s,json_each(s.payload_json,'$.\(path)') v WHERE s.workspace_id=?", columns: 1)
            }
            try append("SELECT sense_id,json_extract(payload_json,'$.note') FROM notebook_collections WHERE workspace_id=?", columns: 1)
            try append("SELECT c.sense_id,t.value FROM notebook_collections c,json_each(c.payload_json,'$.tags') t WHERE c.workspace_id=?", columns: 1)
            try append("""
                SELECT c.sense_id,json_extract(b.payload_json,'$.content.text._0.text'),json_extract(b.payload_json,'$.content.image.caption')
                FROM notebook_collections c JOIN notebook_blocks b ON b.workspace_id=c.workspace_id AND b.parent_id=c.id WHERE c.workspace_id=?
                """, columns: 2)
            try append("SELECT parent_id,json_extract(payload_json,'$.result.meaning'),json_extract(payload_json,'$.result.explanation') FROM notebook_sense_explanations WHERE workspace_id=?", columns: 2)
            // Resolve the narrow accepted-use join before reading source payloads. Reading the
            // wide source rows in physical order avoids repeatedly evicting SQLite pages while
            // hopping between occurrence/source indexes on a large, context-heavy notebook.
            // rowid is transient read order inside this transaction, never durable identity.
            try append("""
                WITH accepted AS MATERIALIZED (
                    SELECT u.sense_id,json_extract(u.payload_json,'$.meaning') AS meaning,
                           json_extract(u.payload_json,'$.translation') AS translation,s.rowid AS source_row
                    FROM notebook_usages u JOIN notebook_occurrences o ON o.workspace_id=u.workspace_id AND o.id=u.occurrence_id
                    JOIN notebook_sources s ON s.workspace_id=o.workspace_id AND s.id=o.parent_id
                    WHERE u.workspace_id=? AND u.status='accepted' ORDER BY s.rowid
                )
                SELECT a.sense_id,a.meaning,a.translation,json_extract(s.payload_json,'$.text')
                FROM accepted a JOIN notebook_sources s ON s.rowid=a.source_row
                """, columns: 3)
            try append("SELECT u.sense_id,json_extract(v.value,'$.text') FROM notebook_usages u,json_each(u.payload_json,'$.translationVariants') v WHERE u.workspace_id=? AND u.status='accepted'", columns: 1)
            try append("""
                SELECT u.sense_id,json_extract(x.payload_json,'$.result.meaning'),json_extract(x.payload_json,'$.result.explanation')
                FROM notebook_usages u JOIN notebook_usage_explanations x ON x.workspace_id=u.workspace_id AND x.parent_id=u.id
                WHERE u.workspace_id=? AND u.status='accepted'
                """, columns: 2)
            var nodes: [UUID: [Int]] = [:]
            for (id, values) in try core.query(sql: "SELECT id,json_extract(payload_json,'$.definition'),json_extract(payload_json,'$.scopeNote') FROM notebook_meaning_nodes WHERE workspace_id=?", values: [.text(workspace)], map: { row -> (UUID, [String]) in
                guard let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)) else { throw VocabularyError.invalidArchive }
                return (id, [1,2].map { DatabaseCore.columnOptionalText(statement: row, index: Int32($0)) ?? "" })
            }) { nodes[id] = values.map { texts.intern($0) } }
            for (id, text) in try core.query(sql: "SELECT parent_id,text FROM notebook_meaning_labels WHERE workspace_id=?", values: [.text(workspace)], map: { row -> (UUID, String) in
                guard let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)) else { throw VocabularyError.invalidArchive }
                return (id, DatabaseCore.columnText(statement: row, index: 1))
            }) { nodes[id, default: []].append(texts.intern(text)) }
            let mappings = try core.query(sql: """
                SELECT parent_id,meaning_id,json_extract(payload_json,'$.conditions'),json_extract(payload_json,'$.nuance')
                FROM notebook_meaning_mappings WHERE workspace_id=? AND json_extract(payload_json,'$.provenance.status')='confirmed'
                """, values: [.text(workspace)]) { row -> NotebookLiteralSearchMaterial.Mapping in
                guard let sense = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)),
                      let node = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 1)) else { throw VocabularyError.invalidArchive }
                return .init(sense: sense, node: node, text: texts.intern((DatabaseCore.columnOptionalText(statement: row, index: 2) ?? "") + " " + (DatabaseCore.columnOptionalText(statement: row, index: 3) ?? "")))
            }
            let cues = try core.query(sql: """
                SELECT c.text,t.meaning_id FROM notebook_retrieval_cues c JOIN notebook_cue_targets t
                ON t.workspace_id=c.workspace_id AND t.parent_id=c.id WHERE c.workspace_id=? AND json_extract(t.payload_json,'$.provenance.status')='confirmed'
                """, values: [.text(workspace)]) { row -> NotebookLiteralSearchMaterial.Link in
                guard let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 1)) else { throw VocabularyError.invalidArchive }
                return .init(text: texts.intern(DatabaseCore.columnText(statement: row, index: 0)), target: id)
            }
            let patterns = try core.query(sql: """
                SELECT parent_id,template,json_extract(payload_json,'$.note'),json_extract(payload_json,'$.collocations')
                FROM notebook_usage_patterns WHERE workspace_id=? AND json_extract(payload_json,'$.provenance.status')='confirmed'
                """, values: [.text(workspace)]) { row -> NotebookLiteralSearchMaterial.Link in
                guard let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)) else { throw VocabularyError.invalidArchive }
                let json = DatabaseCore.columnOptionalText(statement: row, index: 3) ?? "[]"
                let collocations = try core.decoder.decode([String].self, from: Data(json.utf8))
                return .init(text: texts.intern(DatabaseCore.columnText(statement: row, index: 1) + " " + (DatabaseCore.columnOptionalText(statement: row, index: 2) ?? "") + " " + collocations.joined(separator: " ")), target: id)
            }
            try Task.checkCancellation()
            return .init(entryDates: dates, texts: texts.finish(), headers: headerOrder.compactMap { headers[$0] }, fields: fields, nodes: nodes, mappings: mappings,
                cues: cues, patterns: patterns, fence: fence, locale: locale)
        }
    }
}
