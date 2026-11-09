import Foundation
import LingroveNotebook

/// SQLite keeps evidence and rich sense fields in separate rows for bounded writes. The codec
/// reconstructs one saved corpus. Accepted interpretations are the persisted example links.
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
        for (position, claim) in document.interpretations.enumerated() { append(claim, position: position, to: &rows) }
        for (position, entry) in document.catalog.enumerated() { append(entry, position: position, to: &rows) }
        for (position, collection) in VocabularySenseStorageRecord.records(for: document).enumerated() { append(collection, position: position, to: &rows) }
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

    static func append(_ claim: VocabularyInterpretation, position: Int, to rows: inout [Row]) {
        var header = claim; header.explanations = []
        rows.append(.init(table: .usages, id: claim.id.uuidString, parentID: nil, position: position,
            payload: .usage(header), extra: [claim.occurrenceID.uuidString, claim.senseID?.uuidString, claim.status.rawValue]))
        append(claim.explanations, parent: claim.id.uuidString, table: .usageExplanations, to: &rows)
    }

    static func append(_ entry: VocabularyEntry, position: Int, to rows: inout [Row]) {
        var header = entry; header.senses = []
        rows.append(.init(table: .entries, id: entry.id.uuidString, parentID: nil, position: position, payload: .entry(header),
            extra: [VocabularyIdentityPolicy.entryKey(entry), entry.language?.rawValue ?? "und", entry.expression]))
        for (position, sense) in entry.senses.enumerated() {
            var header = sense; header.explanations = []
            VocabularySenseStorageRecord.stripFields(from: &header)
            rows.append(.init(table: .senses, id: sense.id.uuidString, parentID: entry.id.uuidString,
                position: position, payload: .sense(header), extra: [sense.meaning]))
            append(sense.explanations, parent: sense.id.uuidString, table: .senseExplanations, to: &rows)
        }
    }

    static func append(_ collection: VocabularySenseStorageRecord, position: Int, to rows: inout [Row]) {
        let id = collection.id.uuidString
        var header = collection
        header.interpretationIDs = []; header.review = nil
        header.content = collection.content == nil ? nil : []
        header.reviewCards = collection.reviewCards == nil ? nil : []
        rows.append(.init(table: .collections, id: id, parentID: nil, position: position,
            payload: .collection(header), extra: [collection.senseID.uuidString]))
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

    static func document(_ rows: [Row], hasTemplates: Bool, migratingDevCorpus: Bool = false) throws -> VocabularyDocument {
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
        var result = VocabularyDocument(catalog: entries, sources: sources, occurrences: occurrences,
            interpretations: interpretations,
            reviewTemplates: hasTemplates ? templates : nil, semantics: try VocabularySemanticDatabaseProjection.index(rows),
            classification: try VocabularyClassificationRows.index(rows))
        let records = try graph.all(.collections).map { try graph.collection($0) }
        if migratingDevCorpus { return try migrateDevCorpus(result, records: records) }
        try VocabularySenseStorageRecord.materialize(records, in: &result)
        // Round-tripping rejects orphan records, inconsistent indexes and nested children
        // smuggled into scalar headers instead of discarding evidence on reopen.
        guard try self.rows(result) == Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) }) else {
            throw VocabularyError.invalidArchive
        }
        return result
    }

    /// The old notebook listed only its saved senses and selected examples. Preserve that exact
    /// visible graph during the one-time cutover. The external SQLite backup retains the rest.
    private static func migrateDevCorpus(
        _ original: VocabularyDocument, records: [VocabularySenseStorageRecord]
    ) throws -> VocabularyDocument {
        let metadata = Dictionary(grouping: records, by: \.senseID)
        let senses = Set(original.catalog.flatMap(\.senses).map(\.id))
        let claims = Dictionary(grouping: original.interpretations, by: \.id)
        var selected = Set<UUID>()
        for (sense, values) in metadata {
            guard senses.contains(sense), values.count == 1, let record = values.first else {
                throw VocabularyError.invalidArchive
            }
            for id in record.interpretationIDs {
                guard selected.insert(id).inserted, let values = claims[id], values.count == 1,
                      let claim = values.first, claim.senseID == sense, claim.status == .accepted else {
                    throw VocabularyError.invalidArchive
                }
            }
        }
        var next = original
        next.catalog = original.catalog.compactMap { original in
            var entry = original
            entry.senses = original.senses.compactMap { original in
                guard let record = metadata[original.id]?.first else { return nil }
                var sense = original
                record.apply(to: &sense)
                return sense
            }
            return entry.senses.isEmpty ? nil : entry
        }
        let visibleOccurrences = Set(original.interpretations.filter { selected.contains($0.id) }.map(\.occurrenceID))
        next.interpretations = original.interpretations.compactMap { original in
            if original.status == .accepted { return selected.contains(original.id) ? original : nil }
            guard visibleOccurrences.contains(original.occurrenceID) else { return nil }
            var claim = original
            if let sense = claim.senseID, metadata[sense] == nil { claim.senseID = nil }
            return claim
        }
        next.occurrences.removeAll { !visibleOccurrences.contains($0.id) }
        let sourceIDs = Set(next.occurrences.map(\.sourceID))
        next.sources.removeAll { !sourceIDs.contains($0.id) }
        let visible = next.entries
        VocabularySemanticPolicy.reconcile(&next.semantics, previous: original, entries: visible)
        try VocabularyDocumentValidation.validate(next)
        return next
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
        func collection(_ row: Row) throws -> VocabularySenseStorageRecord {
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
