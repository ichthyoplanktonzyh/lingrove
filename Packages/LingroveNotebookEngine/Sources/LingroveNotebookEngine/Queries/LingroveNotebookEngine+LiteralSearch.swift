import Foundation
import LingroveNotebook
import SQLite3

/// A browser actor owns this disposable retrieval material. It contains searchable strings,
/// summary destinations and confirmed joins, never a document, image bytes or writer proof.
/// Reuse requires the exact corpus fence and locale; raw writes invalidate it as revisions do.
public nonisolated struct NotebookLiteralSearchMaterial: Sendable {
    struct Mapping: Sendable { let sense: UUID; let node: UUID; let text: Field }
    let headers: [NotebookEntrySummary]
    let fields: [UUID: [Field]]
    let nodes: [UUID: [Field]]
    let mappings: [Mapping]
    let cues: [(Field, UUID)]
    let patterns: [(Field, UUID)]
    public let fence: NotebookBrowseFence
    public let locale: String

    struct Field: Sendable {
        let text: String
        let ascii: String?
        init(_ text: String) { self.text = text; ascii = text.utf8.allSatisfy { $0 < 128 } ? text.lowercased() : nil }
    }
    /// The matcher caches repeated field decisions for one query only. Non-ASCII and Turkic
    /// case folding retain Foundation's literal user-facing semantics instead of SQLite LIKE.
    struct Matcher {
        let locale: Locale
        let asciiTerms: [String: String]
        var decisions: [String: [String: Bool]] = [:]
        init(locale: Locale, terms: [String]) {
            self.locale = locale
            asciiTerms = Dictionary(terms.filter { $0.utf8.allSatisfy { $0 < 128 } }.map { ($0, $0.lowercased()) }, uniquingKeysWith: { first, _ in first })
        }
        mutating func contains(_ field: Field, _ term: String) -> Bool {
            if let cached = decisions[term]?[field.text] { return cached }
            let language = locale.language.languageCode?.identifier
            let result: Bool
            if language != "tr", language != "az", let ascii = field.ascii, let needle = asciiTerms[term] {
                result = ascii.range(of: needle, options: .literal) != nil
            } else { result = field.text.localizedStandardContains(term) }
            decisions[term, default: [:]][field.text] = result
            return result
        }
    }

    public func results(matching query: String) throws -> NotebookSearchResults {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if phrase.isEmpty { return .init(fence: fence, entries: headers) }
        let terms = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        var matcher = Matcher(locale: Locale(identifier: locale), terms: terms + [phrase])
        var direct = Set<UUID>()
        for (sense, values) in fields {
            try Task.checkCancellation()
            if terms.allSatisfy({ term in values.contains { matcher.contains($0, term) } }) { direct.insert(sense) }
        }
        var matchedNodes = Set<UUID>()
        for (id, values) in nodes where values.contains(where: { matcher.contains($0, phrase) }) { matchedNodes.insert(id) }
        for (text, node) in cues where matcher.contains(text, phrase) { matchedNodes.insert(node) }
        var patternSenses = Set<UUID>()
        for (text, sense) in patterns where matcher.contains(text, phrase) { patternSenses.insert(sense) }
        for mapping in mappings where direct.contains(mapping.sense) || patternSenses.contains(mapping.sense) || matcher.contains(mapping.text, phrase) {
            matchedNodes.insert(mapping.node)
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
            var fields: [UUID: [NotebookLiteralSearchMaterial.Field]] = [:]
            var headerOrder: [UUID] = [], headers: [UUID: NotebookEntrySummary] = [:]
            let rows = try core.query(sql: """
                SELECT e.id,e.expression,e.language,json_extract(e.payload_json,'$.dictionaryForm'),
                       s.id,s.meaning,
                       CASE WHEN s.meaning='' THEN COALESCE((SELECT json_extract(b.payload_json,'$.content.text._0.text')
                        FROM notebook_collections c JOIN notebook_blocks b ON b.workspace_id=c.workspace_id AND b.parent_id=c.id
                        WHERE c.workspace_id=s.workspace_id AND c.sense_id=s.id AND json_type(b.payload_json,'$.content.text')='object'
                        ORDER BY b.position LIMIT 1),'') ELSE '' END,
                       CASE WHEN s.meaning='' THEN EXISTS(SELECT 1 FROM notebook_blocks b WHERE b.workspace_id=s.workspace_id AND b.parent_id=s.id
                        AND json_type(b.payload_json,'$.content.image')='object') ELSE 0 END
                FROM notebook_entries e JOIN notebook_senses s ON s.workspace_id=e.workspace_id AND s.parent_id=e.id
                WHERE e.workspace_id=?
                ORDER BY json_extract(e.payload_json,'$.createdAt') DESC,e.id,json_extract(s.payload_json,'$.createdAt'),s.id
                """, values: [.text(workspace)]) { row -> (UUID, String, LearningLanguage?, String, NotebookEntrySummary.Sense) in
                try Task.checkCancellation()
                guard let entry = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)),
                      let sense = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 4)) else { throw VocabularyError.invalidArchive }
                let meaning = DatabaseCore.columnText(statement: row, index: 5)
                return (entry, DatabaseCore.columnText(statement: row, index: 1),
                    LearningLanguage(rawValue: DatabaseCore.columnText(statement: row, index: 2)),
                    DatabaseCore.columnOptionalText(statement: row, index: 3) ?? "",
                    .init(id: sense, title: meaning.isEmpty ? DatabaseCore.columnText(statement: row, index: 6) : meaning,
                        hasImage: sqlite3_column_int(row, 7) != 0))
            }
            for (id, expression, language, dictionary, sense) in rows {
                if let prior = headers[id] {
                    headers[id] = .init(id: id, expression: expression, language: language, senses: prior.senses + [sense])
                } else { headerOrder.append(id); headers[id] = .init(id: id, expression: expression, language: language, senses: [sense]) }
                fields[sense.id] = [expression, dictionary].map(NotebookLiteralSearchMaterial.Field.init)
            }
            func append(_ sql: String, columns: Int) throws {
                _ = try core.query(sql: sql, values: [.text(workspace)]) { row -> Bool in
                    try Task.checkCancellation()
                    guard let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)), fields[id] != nil else { return false }
                    for column in 1...columns {
                        if let text = DatabaseCore.columnOptionalText(statement: row, index: Int32(column)), !text.isEmpty {
                            fields[id, default: []].append(.init(text))
                        }
                    }
                    return true
                }
            }
            try append("SELECT id,meaning FROM notebook_senses WHERE workspace_id=?", columns: 1)
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
            try append("""
                SELECT u.sense_id,json_extract(u.payload_json,'$.meaning'),json_extract(u.payload_json,'$.translation'),json_extract(s.payload_json,'$.text')
                FROM notebook_usages u JOIN notebook_occurrences o ON o.workspace_id=u.workspace_id AND o.id=u.occurrence_id
                JOIN notebook_sources s ON s.workspace_id=o.workspace_id AND s.id=o.parent_id WHERE u.workspace_id=? AND u.status='accepted'
                """, columns: 3)
            try append("SELECT u.sense_id,json_extract(v.value,'$.text') FROM notebook_usages u,json_each(u.payload_json,'$.translationVariants') v WHERE u.workspace_id=? AND u.status='accepted'", columns: 1)
            try append("""
                SELECT u.sense_id,json_extract(x.payload_json,'$.result.meaning'),json_extract(x.payload_json,'$.result.explanation')
                FROM notebook_usages u JOIN notebook_usage_explanations x ON x.workspace_id=u.workspace_id AND x.parent_id=u.id
                WHERE u.workspace_id=? AND u.status='accepted'
                """, columns: 2)
            var nodes: [UUID: [NotebookLiteralSearchMaterial.Field]] = [:]
            for (id, values) in try core.query(sql: "SELECT id,json_extract(payload_json,'$.definition'),json_extract(payload_json,'$.scopeNote') FROM notebook_meaning_nodes WHERE workspace_id=?", values: [.text(workspace)], map: { row -> (UUID, [String]) in
                guard let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)) else { throw VocabularyError.invalidArchive }
                return (id, [1,2].map { DatabaseCore.columnOptionalText(statement: row, index: Int32($0)) ?? "" })
            }) { nodes[id] = values.map(NotebookLiteralSearchMaterial.Field.init) }
            for (id, text) in try core.query(sql: "SELECT parent_id,text FROM notebook_meaning_labels WHERE workspace_id=?", values: [.text(workspace)], map: { row -> (UUID, String) in
                guard let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)) else { throw VocabularyError.invalidArchive }
                return (id, DatabaseCore.columnText(statement: row, index: 1))
            }) { nodes[id, default: []].append(.init(text)) }
            let mappings = try core.query(sql: """
                SELECT parent_id,meaning_id,json_extract(payload_json,'$.conditions'),json_extract(payload_json,'$.nuance')
                FROM notebook_meaning_mappings WHERE workspace_id=? AND json_extract(payload_json,'$.provenance.status')='confirmed'
                """, values: [.text(workspace)]) { row -> NotebookLiteralSearchMaterial.Mapping in
                guard let sense = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)),
                      let node = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 1)) else { throw VocabularyError.invalidArchive }
                return .init(sense: sense, node: node, text: .init((DatabaseCore.columnOptionalText(statement: row, index: 2) ?? "") + " " + (DatabaseCore.columnOptionalText(statement: row, index: 3) ?? "")))
            }
            let cues = try core.query(sql: """
                SELECT c.text,t.meaning_id FROM notebook_retrieval_cues c JOIN notebook_cue_targets t
                ON t.workspace_id=c.workspace_id AND t.parent_id=c.id WHERE c.workspace_id=? AND json_extract(t.payload_json,'$.provenance.status')='confirmed'
                """, values: [.text(workspace)]) { row -> (NotebookLiteralSearchMaterial.Field, UUID) in
                guard let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 1)) else { throw VocabularyError.invalidArchive }
                return (.init(DatabaseCore.columnText(statement: row, index: 0)), id)
            }
            let patterns = try core.query(sql: """
                SELECT parent_id,template,json_extract(payload_json,'$.note'),json_extract(payload_json,'$.collocations')
                FROM notebook_usage_patterns WHERE workspace_id=? AND json_extract(payload_json,'$.provenance.status')='confirmed'
                """, values: [.text(workspace)]) { row -> (NotebookLiteralSearchMaterial.Field, UUID) in
                guard let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)) else { throw VocabularyError.invalidArchive }
                let json = DatabaseCore.columnOptionalText(statement: row, index: 3) ?? "[]"
                let collocations = try core.decoder.decode([String].self, from: Data(json.utf8))
                return (.init(DatabaseCore.columnText(statement: row, index: 1) + " " + (DatabaseCore.columnOptionalText(statement: row, index: 2) ?? "") + " " + collocations.joined(separator: " ")), id)
            }
            try Task.checkCancellation()
            return .init(headers: headerOrder.compactMap { headers[$0] }, fields: fields, nodes: nodes, mappings: mappings,
                cues: cues, patterns: patterns, fence: fence, locale: locale)
        }
    }
}
