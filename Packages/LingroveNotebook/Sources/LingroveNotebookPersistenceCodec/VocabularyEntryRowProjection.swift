import Foundation
import LingroveNotebook

/// The connection retains this lossless row projection beside its validated document. A narrow
/// entry command replaces only entry/interpretation/collection groups and appended evidence;
/// unchanged category, template and corpus payloads are reused without encoding or diffing them.
/// This is in-memory derived state, never a second persistence format or a caller baseline.
public nonisolated struct VocabularyEntryRowProjection: Sendable {
    private typealias Key = VocabularyPersistenceRow.Key
    private var keyed: [Key: VocabularyPersistenceRow]
    private var groups: [Key: Set<Key>]
    private var semanticKeys: Set<Key>

    public init(_ rows: VocabularyPersistenceRows) throws {
        keyed = try rows.keyedRows(); groups = [:]; semanticKeys = []
        for row in rows.rows {
            if let root = try Self.root(row, rows: keyed) { groups[root, default: []].insert(row.key) }
            if Self.isSemantic(row.entity) { semanticKeys.insert(row.key) }
        }
    }

    /// Exposed for lossless reconstruction checks; ordinary saves consume just changed/removed.
    public func rows(reviewTemplatesPresent: Bool) -> VocabularyPersistenceRows {
        .init(rows: Array(keyed.values), reviewTemplatesPresent: reviewTemplatesPresent)
    }

    public func applying(_ change: VocabularyEntrySaveChange) throws -> VocabularyEntryRowChange {
        var next = self, delta = Delta()
        let document = change.document, previous = change.previous
        let senses = change.affectedSenseIDs
        guard let entryPosition = document.catalog.firstIndex(where: { $0.id == change.entryID }) else {
            throw VocabularyError.invalidArchive
        }
        var records: [VocabularyDatabaseRecord] = []
        VocabularyDatabaseProjection.append(document.catalog[entryPosition], position: entryPosition, to: &records)
        try next.replaceGroup(.init(entity: .entries, id: change.entryID.uuidString), records: records, delta: &delta)

        // replaceEntry never rewrites retained evidence: a correction appends new identities.
        for (position, source) in document.sources.enumerated().dropFirst(previous.sources.count) {
            try next.replace(keys: [], records: [.init(table: .sources, id: source.id.uuidString, parentID: nil,
                position: position, payload: .source(source))], delta: &delta)
        }
        for (position, occurrence) in document.occurrences.enumerated().dropFirst(previous.occurrences.count) {
            try next.replace(keys: [], records: [.init(table: .occurrences, id: occurrence.id.uuidString,
                parentID: occurrence.sourceID.uuidString, position: position, payload: .occurrence(occurrence))], delta: &delta)
        }
        let claims = Set((previous.interpretations + document.interpretations).filter {
            $0.senseID.map(senses.contains) == true
        }.map(\.id))
        let liveClaims = Set(document.interpretations.map(\.id))
        for claim in previous.interpretations where claims.contains(claim.id) && !liveClaims.contains(claim.id) {
            try next.replaceGroup(.init(entity: .usages, id: claim.id.uuidString), records: [], delta: &delta)
        }
        for (position, claim) in document.interpretations.enumerated() {
            let key = Key(entity: .usages, id: claim.id.uuidString)
            if claims.contains(claim.id) {
                records = []; VocabularyDatabaseProjection.append(claim, position: position, to: &records)
                try next.replaceGroup(key, records: records, delta: &delta)
            } else { try next.reposition(key, position: position, delta: &delta) }
        }
        let liveCollections = Set(document.collections.map(\.id))
        for collection in previous.collections where senses.contains(collection.senseID) && !liveCollections.contains(collection.id) {
            try next.replaceGroup(.init(entity: .collections, id: collection.id.uuidString), records: [], delta: &delta)
        }
        for (position, collection) in document.collections.enumerated() {
            let key = Key(entity: .collections, id: collection.id.uuidString)
            if senses.contains(collection.senseID) {
                records = []; VocabularyDatabaseProjection.append(collection, position: position, to: &records)
                try next.replaceGroup(key, records: records, delta: &delta)
            } else { try next.reposition(key, position: position, delta: &delta) }
        }
        // The narrow command can only reconcile identity/evidence/status in patterns/mappings;
        // it cannot introduce a canonically equal Unicode edit into this unchanged graph.
        if previous.semantics != document.semantics {
            records = VocabularySemanticDatabaseProjection.rows(document.semantics)
            try next.replace(keys: semanticKeys, records: records, delta: &delta)
            next.semanticKeys = Set(records.map { .init(entity: $0.table, id: $0.id) })
        }
        return .init(projection: next, changed: delta.changed, removed: delta.removed)
    }

    private struct Delta {
        var changed: [VocabularyPersistenceRow] = []
        var removed: [VocabularyPersistenceRow] = []
    }

    private mutating func replaceGroup(_ root: Key, records: [VocabularyDatabaseRecord], delta: inout Delta) throws {
        try replace(keys: groups[root] ?? [], records: records, delta: &delta)
        groups[root] = records.isEmpty ? nil : Set(records.map { .init(entity: $0.table, id: $0.id) })
    }

    private mutating func replace(keys: Set<Key>, records: [VocabularyDatabaseRecord], delta: inout Delta) throws {
        let rows = try records.map(VocabularyPersistenceRow.init(record:))
        let incoming = Set(rows.map(\.key))
        guard incoming.count == rows.count else { throw VocabularyError.invalidArchive }
        for key in keys.subtracting(incoming) {
            if let old = keyed.removeValue(forKey: key) { delta.removed.append(old) }
        }
        for row in rows {
            let old = keyed[row.key]
            guard old == nil || keys.contains(row.key) else { throw VocabularyError.invalidArchive }
            if let old, old == row, try old.encodedPayload() == row.encodedPayload() { continue }
            keyed[row.key] = row; delta.changed.append(row)
        }
    }

    private mutating func reposition(_ key: Key, position: Int, delta: inout Delta) throws {
        guard let old = keyed[key] else { throw VocabularyError.invalidArchive }
        guard old.position != position else { return }
        let record = old.record
        let row = try VocabularyPersistenceRow(record: .init(table: record.table, id: record.id,
            parentID: record.parentID, position: position, payload: record.payload, extra: record.extra))
        keyed[key] = row; delta.changed.append(row)
    }

    private static func root(_ row: VocabularyPersistenceRow, rows: [Key: VocabularyPersistenceRow]) throws -> Key? {
        switch row.entity {
        case .entries, .usages, .collections: return row.key
        case .senses, .senseExplanations, .usageExplanations, .collectionInterpretations, .blocks, .reviews, .bindings:
            guard let parent = row.entity.parent, let id = row.parentID,
                  let owner = rows[.init(entity: parent, id: id)] else { throw VocabularyError.invalidArchive }
            return try root(owner, rows: rows)
        default: return nil
        }
    }

    private static func isSemantic(_ entity: VocabularyPersistenceEntity) -> Bool {
        switch entity {
        case .meaningNodes, .meaningLabels, .meaningRoles, .usagePatterns, .patternSlots, .meaningMappings,
             .mappingRoles, .mappingEvidence, .meaningRelations, .retrievalCues, .cueTargets: true
        default: false
        }
    }
}

/// A prepared delta belongs to the same connection-owned projection as its entry change. The
/// writer consumes its rows for atomic SQL and journal work, and retains projection only on success.
public nonisolated struct VocabularyEntryRowChange: Sendable {
    public let projection: VocabularyEntryRowProjection
    public let changed: [VocabularyPersistenceRow]
    public let removed: [VocabularyPersistenceRow]
}
