import Foundation
import LingroveNotebook

/// SQLite keeps evidence and rich sense fields in separate rows for bounded writes. The codec
/// reconstructs one saved corpus. Accepted interpretations are the persisted example links.
nonisolated enum VocabularyDatabaseProjection {
    typealias Row = VocabularyDatabaseRecord
    static func rows(_ document: VocabularyDocument, appendingTo previous: VocabularyDocument? = nil,
                     validated: Bool = false) throws -> [Row.Key: Row] {
        var result: [Row.Key: Row] = [:]
        try visitRows(document, appendingTo: previous, validated: validated) { row in
            guard result.updateValue(row, forKey: row.key) == nil else { throw VocabularyError.invalidArchive }
        }
        return result
    }

    /// Full diff callers need independently keyed values, not a globally sorted row list.
    /// This visitor is also the single row-shape authority used for lossless cold reads.
    static func visitRows(_ document: VocabularyDocument, appendingTo previous: VocabularyDocument? = nil,
                          validated: Bool = false, _ visit: (Row) throws -> Void) throws {
        if previous == nil && !validated { try VocabularyLifecyclePolicy.validate(document) }
        for (position, source) in document.sources.enumerated().dropFirst(previous?.sources.count ?? 0) {
            try visit(.init(table: .sources, id: source.id.uuidString, parentID: nil,
                position: position, payload: .source(source)))
        }
        for (position, occurrence) in document.occurrences.enumerated().dropFirst(previous?.occurrences.count ?? 0) {
            try visit(.init(table: .occurrences, id: occurrence.id.uuidString, parentID: occurrence.sourceID.uuidString,
                position: position, payload: .occurrence(occurrence)))
        }
        var children: [Row] = []
        for (position, claim) in document.interpretations.enumerated().dropFirst(previous?.interpretations.count ?? 0) {
            children.removeAll(keepingCapacity: true); append(claim, position: position, to: &children)
            for row in children { try visit(row) }
        }
        let newEntries = document.catalog.dropFirst(previous?.catalog.count ?? 0)
        for (position, entry) in zip(newEntries.indices, newEntries) {
            children.removeAll(keepingCapacity: true); append(entry, position: position, to: &children)
            for row in children { try visit(row) }
        }
        let previousSenses = previous?.catalog.reduce(0) { $0 + $1.senses.count } ?? 0
        for (offset, collection) in VocabularySenseStorageRecord.records(for: newEntries).enumerated() {
            children.removeAll(keepingCapacity: true); append(collection, position: previousSenses + offset, to: &children)
            for row in children { try visit(row) }
        }
        if previous == nil && !validated {
            try VocabularySemanticPolicy.validate(document.semantics, entries: document.entries)
            try VocabularyClassificationPolicy.validate(document.classification, nodes: document.semantics.nodes)
        }
        for row in VocabularySemanticDatabaseProjection.rows(document.semantics, appendingTo: previous?.semantics) { try visit(row) }
        for row in VocabularyClassificationRows.rows(document.classification, appendingTo: previous?.classification) { try visit(row) }
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
        header.interpretationIDs = []
        header.content = collection.content == nil ? nil : []
        rows.append(.init(table: .collections, id: id, parentID: nil, position: position,
            payload: .collection(header), extra: [collection.senseID.uuidString]))
        for (position, block) in (collection.content ?? []).enumerated() {
            rows.append(.init(table: .blocks, id: block.id.uuidString, parentID: id, position: position, payload: .block(block)))
        }

    }

    private static func append(_ records: [LearningExplanationRecord], parent: String, table: Row.Table, to rows: inout [Row]) {
        for (position, record) in records.enumerated() {
            rows.append(.init(table: table, id: parent + ":" + record.id.uuidString, parentID: parent,
                position: position, payload: .explanation(record)))
        }
    }

    static func document(_ rows: [Row], migratingDevCorpus: Bool = false) throws -> VocabularyDocument {
        let index = try VocabularyDatabaseRowIndex(rows)
        let document = try reconstruct(index, migratingDevCorpus: migratingDevCorpus)
        if !migratingDevCorpus { try checkRows(index, document: document, validated: false) }
        return document
    }

    /// One full validation establishes the joined-entry proof and the lossless row check.
    /// The writer can retain it instead of immediately repeating both after a cold SQL read.
    static func state(_ rows: [Row], migratingDevCorpus: Bool = false) throws -> VocabularyEntrySaveState {
        let index = try VocabularyDatabaseRowIndex(rows)
        let document = try reconstruct(index, migratingDevCorpus: migratingDevCorpus)
        let state = try VocabularyEntrySaveState(validating: document)
        if !migratingDevCorpus {
            try checkRows(index, document: document, validated: true)
        }
        return state
    }

    private static func checkRows(_ index: VocabularyDatabaseRowIndex, document: VocabularyDocument, validated: Bool) throws {
        var matched = [Bool](repeating: false, count: index.rows.count), count = 0
        // Each expected row must consume exactly one original row. A flag per offset rejects
        // duplicates and untouched orphans without constructing a second full payload table.
        try visitRows(document, validated: validated) { expected in
            guard let offset = index.offset(for: expected.key), !matched[offset], index.rows[offset] == expected else {
                throw VocabularyError.invalidArchive
            }
            matched[offset] = true; count += 1
        }
        guard count == index.rows.count else { throw VocabularyError.invalidArchive }
    }

    private static func reconstruct(_ index: VocabularyDatabaseRowIndex, migratingDevCorpus: Bool) throws -> VocabularyDocument {
        let graph = Graph(index: index)
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
        var result = VocabularyDocument(catalog: entries, sources: sources, occurrences: occurrences, interpretations: interpretations,
            semantics: try VocabularySemanticDatabaseProjection.index(index),
            classification: try VocabularyClassificationRows.index(index))
        let records = try graph.all(.collections).map { try graph.collection($0) }
        if migratingDevCorpus { return try migrateDevCorpus(result, records: records) }
        try VocabularySenseStorageRecord.materialize(records, in: &result)
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
        let index: VocabularyDatabaseRowIndex
        func all(_ table: Row.Table) throws -> [Row] { try index.all(table) }
        func children(_ table: Row.Table, parent: String? = nil) throws -> [Row] {
            try index.children(table, parent: parent)
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
            return value
        }
    }
}
