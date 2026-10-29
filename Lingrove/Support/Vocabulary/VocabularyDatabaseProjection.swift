import Foundation

/// Lossless row mapping follows lifecycle ownership: catalog, source evidence, interpretations
/// and collections each have their own roots. Reopening never regenerates raw evidence from
/// whichever examples happen to be personally collected.
nonisolated enum VocabularyDatabaseProjection {
    typealias Row = VocabularyDatabaseRecord
    private struct Owner: Hashable { let table: Row.Table; let parent: String? }

    static func rows(_ document: VocabularyDocument) throws -> [Row.Key: Row] {
        try VocabularyLifecyclePolicy.validate(document)
        var rows: [Row] = []
        for (position, source) in document.sources.enumerated() {
            rows.append(.init(table: .sources, id: source.id.uuidString, parentID: nil,
                position: position, payload: .source(source)))
        }
        for (position, occurrence) in document.occurrences.enumerated() {
            rows.append(.init(table: .occurrences, id: occurrence.id.uuidString, parentID: occurrence.sourceID.uuidString,
                position: position, payload: .occurrence(occurrence)))
        }
        for (position, claim) in document.interpretations.enumerated() {
            var header = claim; header.explanations = []
            rows.append(.init(table: .usages, id: claim.id.uuidString, parentID: nil, position: position,
                payload: .usage(header), extra: [claim.occurrenceID.uuidString, claim.senseID?.uuidString, claim.status.rawValue]))
            append(claim.explanations, parent: claim.id.uuidString, table: .usageExplanations, to: &rows)
        }
        for (position, entry) in document.catalog.enumerated() {
            var header = entry; header.senses = []
            rows.append(.init(table: .entries, id: entry.id.uuidString, parentID: nil, position: position, payload: .entry(header),
                extra: [VocabularyPolicy.entryKey(entry), entry.language?.rawValue ?? "und", entry.expression]))
            for (position, sense) in entry.senses.enumerated() {
                var header = sense; header.explanations = []
                rows.append(.init(table: .senses, id: sense.id.uuidString, parentID: entry.id.uuidString,
                    position: position, payload: .sense(header), extra: [sense.meaning]))
                append(sense.explanations, parent: sense.id.uuidString, table: .senseExplanations, to: &rows)
            }
        }
        for (position, collection) in document.collections.enumerated() { append(collection, position: position, to: &rows) }
        for (position, template) in (document.reviewTemplates ?? []).enumerated() {
            rows.append(.init(table: .templates, id: template.id.uuidString, parentID: nil,
                position: position, payload: .template(template)))
        }
        try VocabularySemanticPolicy.validate(document.semantics, entries: document.entries)
        rows.append(contentsOf: VocabularySemanticDatabaseProjection.rows(document.semantics))
        try VocabularyClassificationPolicy.validate(document.classification, nodes: document.semantics.nodes)
        rows.append(contentsOf: VocabularyClassificationRows.rows(document.classification))
        guard Set(rows.map(\.key)).count == rows.count else { throw VocabularyError.invalidArchive }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
    }

    private static func append(_ collection: VocabularyCollectionItem, position: Int, to rows: inout [Row]) {
        let id = collection.id.uuidString
        var header = collection
        header.interpretationIDs = []; header.review = nil
        header.content = collection.content == nil ? nil : []
        header.reviewCards = collection.reviewCards == nil ? nil : []
        rows.append(.init(table: .collections, id: id, parentID: nil, position: position,
            payload: .collection(header), extra: [collection.senseID.uuidString]))
        for (position, interpretationID) in collection.interpretationIDs.enumerated() {
            rows.append(.init(table: .collectionInterpretations, id: id + ":" + interpretationID.uuidString,
                parentID: id, position: position, payload: .evidence(interpretationID), extra: [interpretationID.uuidString]))
        }
        for (position, block) in (collection.content ?? []).enumerated() {
            rows.append(.init(table: .blocks, id: block.id.uuidString, parentID: id, position: position, payload: .block(block)))
        }
        if let review = collection.review { append(review, id: id + ":legacy", parent: id, position: 0, to: &rows) }
        for (position, review) in (collection.reviewCards ?? []).enumerated() {
            append(review, id: id + ":card:" + review.plan.id.uuidString, parent: id,
                position: position + (collection.review == nil ? 0 : 1), to: &rows)
        }
    }

    private static func append(_ records: [LearningExplanationRecord], parent: String, table: Row.Table, to rows: inout [Row]) {
        for (position, record) in records.enumerated() {
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
            entry.senses = try graph.children(.senses, parent: row.id).map { row in
                guard case var .sense(sense) = row.payload else { throw VocabularyError.invalidArchive }
                sense.explanations = try graph.explanations(.senseExplanations, parent: row.id); return sense
            }
            return entry
        }
        let sources = try graph.all(.sources).map { row in
            guard case let .source(value) = row.payload else { throw VocabularyError.invalidArchive }; return value
        }
        let occurrences = try graph.all(.occurrences).map { row in
            guard case let .occurrence(value) = row.payload else { throw VocabularyError.invalidArchive }; return value
        }
        let interpretations = try graph.all(.usages).map { row in
            guard case var .usage(value) = row.payload else { throw VocabularyError.invalidArchive }
            value.explanations = try graph.explanations(.usageExplanations, parent: row.id); return value
        }
        let templates = try graph.children(.templates).map { row in
            guard case let .template(value) = row.payload else { throw VocabularyError.invalidArchive }; return value
        }
        let result = VocabularyDocument(catalog: entries, sources: sources, occurrences: occurrences,
            interpretations: interpretations, collections: try graph.all(.collections).map { try graph.collection($0) },
            reviewTemplates: hasTemplates ? templates : nil, semantics: try VocabularySemanticDatabaseProjection.index(rows),
            classification: try VocabularyClassificationRows.index(rows))
        // Round-tripping rejects orphan records, inconsistent indexes and nested children
        // smuggled into scalar headers instead of discarding evidence on reopen.
        guard try self.rows(result) == Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) }) else {
            throw VocabularyError.invalidArchive
        }
        return result
    }

    private struct Graph {
        let rows: [Row]
        let groups: [Owner: [Row]]
        init(rows: [Row]) {
            self.rows = rows
            groups = Dictionary(grouping: rows, by: { .init(table: $0.table, parent: $0.parentID) })
        }
        func all(_ table: Row.Table) throws -> [Row] { try ordered(rows.filter { $0.table == table }) }
        func children(_ table: Row.Table, parent: String? = nil) throws -> [Row] {
            try ordered(groups[.init(table: table, parent: parent)] ?? [])
        }
        private func ordered(_ rows: [Row]) throws -> [Row] {
            let values = rows.sorted { $0.position < $1.position }
            guard values.map(\.position) == Array(values.indices) else { throw VocabularyError.invalidArchive }; return values
        }
        func explanations(_ table: Row.Table, parent: String) throws -> [LearningExplanationRecord] {
            try children(table, parent: parent).map { row in
                guard case let .explanation(value) = row.payload else { throw VocabularyError.invalidArchive }; return value
            }
        }
        func collection(_ row: Row) throws -> VocabularyCollectionItem {
            guard case var .collection(value) = row.payload else { throw VocabularyError.invalidArchive }
            value.interpretationIDs = try children(.collectionInterpretations, parent: row.id).map { row in
                guard case let .evidence(id) = row.payload else { throw VocabularyError.invalidArchive }; return id
            }
            let blocks = try children(.blocks, parent: row.id).map { row in
                guard case let .block(value) = row.payload else { throw VocabularyError.invalidArchive }; return value
            }
            value.content = value.content == nil ? nil : blocks
            for child in try children(.reviews, parent: row.id) {
                guard case var .review(review) = child.payload else { throw VocabularyError.invalidArchive }
                review.bindings = try children(.bindings, parent: child.id).map { row in
                    guard case let .binding(value) = row.payload else { throw VocabularyError.invalidArchive }; return value
                }
                if child.id == row.id + ":legacy" { value.review = review } else {
                    guard value.reviewCards != nil else { throw VocabularyError.invalidArchive }; value.reviewCards?.append(review)
                }
            }
            return value
        }
    }
}
