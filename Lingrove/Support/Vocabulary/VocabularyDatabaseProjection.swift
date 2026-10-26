import Foundation

/// Pure, lossless mapping between the notebook's value graph and independently editable rows.
/// The SQLite owner compares these values before encoding, so unchanged entities perform no IO.
nonisolated enum VocabularyDatabaseProjection {
    typealias Row = VocabularyDatabaseRecord
    private struct Owner: Hashable { let table: Row.Table; let parent: String? }

    static func rows(_ document: VocabularyDocument) throws -> [Row.Key: Row] {
        var rows: [Row] = []
        for (position, entry) in document.entries.enumerated() {
            let parent = entry.id.uuidString
            var header = entry; header.senses = []
            rows.append(.init(table: .entries, id: parent, parentID: nil, position: position, payload: .entry(header),
                extra: [VocabularyPolicy.entryKey(entry), entry.language?.rawValue ?? "und", entry.expression]))
            for (index, sense) in entry.senses.enumerated() { append(sense, parent: parent, position: index, to: &rows) }
        }
        for (position, template) in (document.reviewTemplates ?? []).enumerated() {
            rows.append(.init(table: .templates, id: template.id.uuidString, parentID: nil,
                position: position, payload: .template(template)))
        }
        guard Set(rows.map(\.key)).count == rows.count else { throw VocabularyError.invalidArchive }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
    }

    private static func append(_ sense: VocabularySense, parent: String, position: Int, to rows: inout [Row]) {
        let id = sense.id.uuidString
        var header = sense
        header.examples = []; header.explanations = []; header.review = nil
        header.content = sense.content == nil ? nil : []; header.reviewCards = sense.reviewCards == nil ? nil : []
        rows.append(.init(table: .senses, id: id, parentID: parent, position: position,
            payload: .sense(header), extra: [sense.meaning]))
        append(sense.explanations, parent: id, table: .senseExplanations, to: &rows)
        for (position, usage) in sense.examples.enumerated() {
            var header = usage; header.explanations = []
            rows.append(.init(table: .usages, id: usage.id.uuidString, parentID: id, position: position, payload: .usage(header)))
            append(usage.explanations, parent: usage.id.uuidString, table: .usageExplanations, to: &rows)
        }
        for (position, block) in (sense.content ?? []).enumerated() {
            rows.append(.init(table: .blocks, id: block.id.uuidString, parentID: id, position: position, payload: .block(block)))
        }
        if let review = sense.review { append(review, id: id + ":legacy", parent: id, position: 0, to: &rows) }
        for (position, review) in (sense.reviewCards ?? []).enumerated() {
            append(review, id: id + ":card:" + review.plan.id.uuidString, parent: id,
                position: position + (sense.review == nil ? 0 : 1), to: &rows)
        }
    }

    private static func append(_ records: [LearningExplanationRecord], parent: String, table: Row.Table, to rows: inout [Row]) {
        for (position, record) in records.enumerated() {
            // One cached explanation can be reused by several usages. Its storage key includes
            // the owner, while the public record UUID and exact input remain unchanged.
            rows.append(.init(table: table, id: parent + ":" + record.id.uuidString, parentID: parent,
                position: position, payload: .explanation(record)))
        }
    }

    private static func append(_ review: VocabularyReview, id: String, parent: String, position: Int, to rows: inout [Row]) {
        var header = review; header.bindings = []
        rows.append(.init(table: .reviews, id: id, parentID: parent, position: position, payload: .review(header)))
        for (position, binding) in review.bindings.enumerated() {
            rows.append(.init(table: .bindings, id: id + ":" + binding.id.uuidString, parentID: id,
                position: position, payload: .binding(binding)))
        }
    }

    static func document(_ rows: [Row], hasTemplates: Bool) throws -> VocabularyDocument {
        guard Set(rows.map(\.key)).count == rows.count else { throw VocabularyError.invalidArchive }
        let graph = Graph(rows: rows)
        let entries = try graph.children(.entries).map { row in
            guard case var .entry(entry) = row.payload else { throw VocabularyError.invalidArchive }
            entry.senses = try graph.children(.senses, parent: row.id).map { try graph.sense($0) }
            return entry
        }
        let templates = try graph.children(.templates).map { row in
            guard case let .template(value) = row.payload else { throw VocabularyError.invalidArchive }
            return value
        }
        let result = VocabularyDocument(entries: entries, reviewTemplates: hasTemplates ? templates : nil)
        // Re-projecting catches orphan rows, inconsistent indexed columns, nonempty child arrays
        // smuggled into a header and IDs that disagree with their owning SQL row.
        guard try self.rows(result) == Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) }) else {
            throw VocabularyError.invalidArchive
        }
        return result
    }

    /// One reconstruction index avoids repeatedly scanning every table for every owner.
    private struct Graph {
        let groups: [Owner: [Row]]
        init(rows: [Row]) { groups = Dictionary(grouping: rows, by: { .init(table: $0.table, parent: $0.parentID) }) }
        func children(_ table: Row.Table, parent: String? = nil) throws -> [Row] {
            let values = (groups[.init(table: table, parent: parent)] ?? []).sorted { $0.position < $1.position }
            guard values.map(\.position) == Array(values.indices) else { throw VocabularyError.invalidArchive }
            return values
        }
        func explanations(_ table: Row.Table, parent: String) throws -> [LearningExplanationRecord] {
            try children(table, parent: parent).map { row in
                guard case let .explanation(value) = row.payload else { throw VocabularyError.invalidArchive }; return value
            }
        }
        func sense(_ row: Row) throws -> VocabularySense {
            guard case var .sense(sense) = row.payload else { throw VocabularyError.invalidArchive }
            sense.explanations = try explanations(.senseExplanations, parent: row.id)
            sense.examples = try children(.usages, parent: row.id).map { row in
                guard case var .usage(usage) = row.payload else { throw VocabularyError.invalidArchive }
                usage.explanations = try explanations(.usageExplanations, parent: row.id); return usage
            }
            let blocks = try children(.blocks, parent: row.id).map { row in
                guard case let .block(value) = row.payload else { throw VocabularyError.invalidArchive }; return value
            }
            sense.content = sense.content == nil ? nil : blocks
            for child in try children(.reviews, parent: row.id) {
                guard case var .review(review) = child.payload else { throw VocabularyError.invalidArchive }
                review.bindings = try children(.bindings, parent: child.id).map { row in
                    guard case let .binding(value) = row.payload else { throw VocabularyError.invalidArchive }; return value
                }
                if child.id == row.id + ":legacy" { sense.review = review } else {
                    guard sense.reviewCards != nil else { throw VocabularyError.invalidArchive }
                    sense.reviewCards?.append(review)
                }
            }
            return sense
        }
    }
}
