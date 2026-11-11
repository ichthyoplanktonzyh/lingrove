import Foundation
import LingroveNotebook

/// The connection retains this lossless row projection beside its validated document. A narrow
/// entry command replaces only entry/interpretation/collection groups and appended evidence.
/// Organization commands replace graph/directory rows while reusing lexical payloads.
/// Unchanged rows keep their stored bytes without another JSON encoding pass.
/// This is in-memory derived state, never a second persistence format or a caller baseline.
public nonisolated struct VocabularyEntryRowProjection: Sendable {
    private typealias Key = VocabularyPersistenceRow.Key
    private var keyed: VocabularyProjectionMap<Key, VocabularyPersistenceRow>
    private var groups: VocabularyProjectionMap<Key, Set<Key>>
    private var organizationGroups: VocabularyProjectionMap<Key, Set<Key>>

    public init(_ rows: VocabularyPersistenceRows) throws {
        try self.init(rows, keyed: rows.keyedRows())
    }

    private init(_ rows: VocabularyPersistenceRows, keyed values: [Key: VocabularyPersistenceRow]) throws {
        keyed = .init(values); groups = .init(); organizationGroups = .init()
        var lexicalGroups: [Key: Set<Key>] = [:], graphGroups: [Key: Set<Key>] = [:]
        for row in rows.rows {
            if let root = try Self.root(row, rows: keyed) { lexicalGroups[root, default: []].insert(row.key) }
            if let root = Self.organizationRoot(row) { graphGroups[root, default: []].insert(row.key) }
        }
        groups = .init(lexicalGroups); organizationGroups = .init(graphGroups)
    }

    /// Exposed for lossless reconstruction checks; ordinary saves consume just changed/removed.
    public func rows(reviewTemplatesPresent: Bool) -> VocabularyPersistenceRows {
        .init(rows: Array(keyed.values), reviewTemplatesPresent: reviewTemplatesPresent)
    }

    public func canAppend(_ rows: [VocabularyPersistenceRow]) -> Bool {
        rows.allSatisfy { keyed[$0.key] == nil }
    }

    /// A complete candidate is already validated by the domain module. Diff against this
    /// connection's retained rows, classifying pure moves separately from changed payloads.
    public func replacingDocument(_ document: VocabularyDocument) throws -> VocabularyEntryRowChange {
        try replacingRows(VocabularyPersistenceCodec.encode(document))
    }

    public func replacingDocument(_ state: VocabularyEntrySaveState) throws -> VocabularyEntryRowChange {
        try replacingRows(VocabularyPersistenceCodec.unorderedRows(state))
    }

    private func replacingRows(_ encoded: VocabularyPersistenceRows) throws -> VocabularyEntryRowChange {
        var delta = Delta()
        let after = try encoded.keyedRows()
        for row in encoded.rows {
            if let old = keyed[row.key], old.parentID == row.parentID, old.record.extra == row.record.extra,
               old.record.payload == row.record.payload, try old.hasSameLiteralPayload(as: row) {
                if old.position != row.position { delta.repositioned.append(row) }
            } else { delta.changed.append(row) }
        }
        delta.removed = keyed.values.filter { after[$0.key] == nil }
        let next = try VocabularyEntryRowProjection(encoded, keyed: after)
        return .init(projection: next, changed: delta.changed, removed: delta.removed, repositioned: delta.repositioned)
    }

    /// Proven append-only capture retains every old group and payload, adding just new roots.
    public func appending(_ rows: [VocabularyPersistenceRow]) throws -> VocabularyEntryRowChange {
        guard canAppend(rows) else { throw VocabularyError.invalidArchive }
        var next = self
        for row in rows { next.keyed[row.key] = row }
        for row in rows {
            if let root = try Self.root(row, rows: next.keyed) { next.groups[root, default: []].insert(row.key) }
            if let root = Self.organizationRoot(row) { next.organizationGroups[root, default: []].insert(row.key) }
        }
        return .init(projection: next, changed: rows, removed: [], repositioned: [])
    }

    public func materialRoots(for keys: Set<VocabularyPersistenceRow.Key>) throws -> VocabularyPersistenceMaterialRoots {
        var result = VocabularyPersistenceMaterialRoots()
        for key in keys {
            guard let row = keyed[key] else { continue }
            switch row.entity {
            case .templates: result.allReviewMaterial = true
            case .sources:
                guard let id = UUID(uuidString: row.id) else { throw VocabularyError.invalidArchive }
                result.sourceIDs.insert(id)
            case .occurrences:
                guard let id = UUID(uuidString: row.id) else { throw VocabularyError.invalidArchive }
                result.occurrenceIDs.insert(id)
            default:
                if let root = Self.organizationRoot(row) { result.organizationRoots.insert(root); continue }
                guard let root = try Self.root(row, rows: keyed), let owner = keyed[root] else { continue }
                if root.entity == .usages {
                    guard let id = UUID(uuidString: root.id) else { throw VocabularyError.invalidArchive }
                    result.interpretationIDs.insert(id)
                }
                if root.entity == .entries {
                    guard let id = UUID(uuidString: root.id) else { throw VocabularyError.invalidArchive }
                    result.entryIDs.insert(id)
                } else if let raw = owner.indexValue(.senseID) {
                    guard let id = UUID(uuidString: raw) else { throw VocabularyError.invalidArchive }
                    result.senseIDs.insert(id)
                }
            }
        }
        return result
    }


    /// The sealed domain scope selects complete ownership groups, including removed roots.
    /// A changed node emits its own labels/roles without projecting every other graph row.
    public func applyingOrganization(_ change: VocabularyOrganizationSaveChange) throws -> VocabularyEntryRowChange {
        let scope = change.scope, document = change.state.document
        let graph = VocabularySemanticDatabaseProjection.rows(scope.semantics(in: document.semantics))
        let directory = VocabularyClassificationRows.rows(scope.classification(in: document.classification))
        var roots = Set<Key>()
        func add(_ ids: Set<UUID>, _ entity: VocabularyPersistenceEntity) {
            roots.formUnion(ids.map { .init(entity: entity, id: $0.uuidString) })
        }
        add(scope.nodes, .meaningNodes); add(scope.patterns, .usagePatterns); add(scope.mappings, .meaningMappings)
        add(scope.relations, .meaningRelations); add(scope.cues, .retrievalCues); add(scope.targets, .cueTargets)
        add(scope.categories, .categories); add(scope.parents, .categoryParents)
        add(scope.memberships, .categoryMemberships); add(scope.overrides, .categoryOverrides)
        var records: [Key: [VocabularyDatabaseRecord]] = [:]
        for record in graph + directory {
            let row = try VocabularyPersistenceRow(record: record)
            guard let root = Self.organizationRoot(row) else { throw VocabularyError.invalidArchive }
            records[root, default: []].append(record)
        }
        var next = self, delta = Delta()
        for root in roots {
            let old = organizationGroups[root] ?? (keyed[root] == nil ? [] : [root])
            let incoming = records[root] ?? []
            try next.replace(keys: old, records: incoming, delta: &delta)
            let updated = Set(incoming.map { Key(entity: $0.table, id: $0.id) })
            if old != updated {
                next.organizationGroups[root] = updated.isEmpty ? nil : updated
            }
        }
        return .init(projection: next, changed: delta.changed, removed: delta.removed, repositioned: delta.repositioned)
    }

    /// Removing one tag cannot edit evidence, content or review history. Replace the affected
    /// lexical ownership groups using their checked values; all other rows remain borrowed.
    public func applying(_ change: VocabularyTagRemovalChange) throws -> VocabularyEntryRowChange {
        var next = self, delta = Delta()
        let entries = change.state.document.catalog.filter { change.entryIDs.contains($0.id) }
        for entry in entries {
            var records: [VocabularyDatabaseRecord] = []
            VocabularyDatabaseProjection.append(entry, position: 0, to: &records)
            try next.replaceGroup(.init(entity: .entries, id: entry.id.uuidString), records: records, delta: &delta)
        }
        for collection in VocabularySenseStorageRecord.records(for: entries) {
            var records: [VocabularyDatabaseRecord] = []
            VocabularyDatabaseProjection.append(collection, position: 0, to: &records)
            try next.replaceGroup(.init(entity: .collections, id: collection.id.uuidString), records: records, delta: &delta)
        }
        return .init(projection: next, changed: delta.changed, removed: delta.removed, repositioned: delta.repositioned)
    }

    public func applying(_ change: VocabularyEntrySaveChange) throws -> VocabularyEntryRowChange {
        var next = self, delta = Delta()
        let document = change.document, previous = change.previous
        let senses = change.affectedSenseIDs
        let entryKey = Key(entity: .entries, id: change.entryID.uuidString)
        var records: [VocabularyDatabaseRecord] = []
        if let position = document.catalog.firstIndex(where: { $0.id == change.entryID }) {
            VocabularyDatabaseProjection.append(document.catalog[position], position: position, to: &records)
            try next.replaceGroup(entryKey, records: records, delta: &delta)
        } else {
            guard let position = keyed[entryKey]?.position else { throw VocabularyError.invalidArchive }
            try next.replaceGroup(entryKey, records: [], delta: &delta)
            for (offset, entry) in document.catalog.enumerated().dropFirst(position) {
                try next.reposition(.init(entity: .entries, id: entry.id.uuidString), position: offset, delta: &delta)
            }
        }

        // replaceEntry never rewrites retained evidence: a correction appends new identities.
        for (position, source) in document.sources.enumerated().dropFirst(previous.sources.count) {
            try next.replace(keys: [], records: [.init(table: .sources, id: source.id.uuidString, parentID: nil,
                position: position, payload: .source(source))], delta: &delta)
        }
        for (position, occurrence) in document.occurrences.enumerated().dropFirst(previous.occurrences.count) {
            try next.replace(keys: [], records: [.init(table: .occurrences, id: occurrence.id.uuidString,
                parentID: occurrence.sourceID.uuidString, position: position, payload: .occurrence(occurrence))], delta: &delta)
        }
        let liveClaims = Set(change.claims.map(\.id))
        for claim in change.previousClaims where !liveClaims.contains(claim.id) {
            try next.replaceGroup(.init(entity: .usages, id: claim.id.uuidString), records: [], delta: &delta)
        }
        for claim in change.claims {
            let key = Key(entity: .usages, id: claim.id.uuidString)
            records = []; VocabularyDatabaseProjection.append(claim, position: 0, to: &records)
            try next.replaceGroup(key, records: records, delta: &delta)
        }
        let recordsBySense = VocabularySenseStorageRecord.records(for: document.catalog.filter { $0.id == change.entryID })
        let liveCollections = Set(recordsBySense.map(\.id))
        for collection in VocabularySenseStorageRecord.records(for: previous.catalog.filter { $0.id == change.entryID }) where !liveCollections.contains(collection.id) {
            try next.replaceGroup(.init(entity: .collections, id: collection.id.uuidString), records: [], delta: &delta)
        }
        for (position, collection) in recordsBySense.enumerated() {
            let key = Key(entity: .collections, id: collection.id.uuidString)
            if senses.contains(collection.senseID) {
                records = []; VocabularyDatabaseProjection.append(collection, position: position, to: &records)
                try next.replaceGroup(key, records: records, delta: &delta)
            } else { try next.reposition(key, position: position, delta: &delta) }
        }
        let semantic = change.semanticChange
        if !semantic.isEmpty {
            for id in semantic.removedPatternIDs {
                try next.replaceSemanticGroup(.init(entity: .usagePatterns, id: id.uuidString), records: [], delta: &delta)
            }
            for id in semantic.removedMappingIDs {
                try next.replaceSemanticGroup(.init(entity: .meaningMappings, id: id.uuidString), records: [], delta: &delta)
            }
            let updates = Dictionary(uniqueKeysWithValues: semantic.updatedMappings.map { ($0.id, $0) })
            for (position, value) in document.semantics.patterns.enumerated() {
                try next.reposition(.init(entity: .usagePatterns, id: value.id.uuidString), position: position, delta: &delta)
            }
            for (position, value) in document.semantics.mappings.enumerated() {
                let key = Key(entity: .meaningMappings, id: value.id.uuidString)
                if let updated = updates[value.id] {
                    records = []; VocabularySemanticDatabaseProjection.append(updated, position: position, to: &records)
                    try next.replaceSemanticGroup(key, records: records, delta: &delta)
                } else { try next.reposition(key, position: position, delta: &delta) }
            }
        }
        return .init(projection: next, changed: delta.changed, removed: delta.removed, repositioned: delta.repositioned)
    }

    private struct Delta {
        var changed: [VocabularyPersistenceRow] = []
        var removed: [VocabularyPersistenceRow] = []
        var repositioned: [VocabularyPersistenceRow] = []
    }

    private mutating func replaceSemanticGroup(_ root: Key, records: [VocabularyDatabaseRecord], delta: inout Delta) throws {
        let old = organizationGroups[root] ?? []
        try replace(keys: old, records: records, preservingLiteralPayloads: false, delta: &delta)
        let new = Set(records.map { Key(entity: $0.table, id: $0.id) })
        if old != new {
            organizationGroups[root] = new.isEmpty ? nil : new
        }
    }

    private static func organizationRoot(_ row: VocabularyPersistenceRow) -> Key? {
        switch row.entity {
        case .meaningLabels, .meaningRoles: row.parentID.map { .init(entity: .meaningNodes, id: $0) }
        case .patternSlots: row.parentID.map { .init(entity: .usagePatterns, id: $0) }
        case .mappingRoles, .mappingEvidence: row.parentID.map { .init(entity: .meaningMappings, id: $0) }
        default: isSemantic(row.entity) || isClassification(row.entity) ? row.key : nil
        }
    }

    private mutating func replaceGroup(_ root: Key, records: [VocabularyDatabaseRecord], delta: inout Delta) throws {
        let old = groups[root] ?? []
        try replace(keys: old, records: records, delta: &delta)
        let new = Set(records.map { Key(entity: $0.table, id: $0.id) })
        if old != new { groups[root] = new.isEmpty ? nil : new }
    }

    private mutating func replace(keys: Set<Key>, records: [VocabularyDatabaseRecord],
                                  preservingLiteralPayloads: Bool = true, delta: inout Delta) throws {
        let rows = try records.map(VocabularyPersistenceRow.init(record:))
        let incoming = Set(rows.map(\.key))
        guard incoming.count == rows.count else { throw VocabularyError.invalidArchive }
        for key in keys.subtracting(incoming) {
            if let old = keyed.removeValue(forKey: key) { delta.removed.append(old) }
        }
        for row in rows {
            let old = keyed[row.key]
            guard old == nil || keys.contains(row.key) else { throw VocabularyError.invalidArchive }
            // An unchanged foreign key should not be deleted and reinserted just because a
            // preceding sibling left. For authored rows compare literal payload bytes as well.
            if let old, old.parentID == row.parentID, old.record.extra == row.record.extra,
               old.record.payload == row.record.payload,
               try !preservingLiteralPayloads || old.hasSameLiteralPayload(as: row) {
                if old.position != row.position {
                    keyed[row.key] = row
                    delta.repositioned.append(row)
                }
                continue
            }
            keyed[row.key] = row; delta.changed.append(row)
        }
    }

    private mutating func reposition(_ key: Key, position: Int, delta: inout Delta) throws {
        guard key.entity.hasBusinessOrder else { return }
        guard let old = keyed[key] else { throw VocabularyError.invalidArchive }
        guard old.position != position else { return }
        let record = old.record
        let row = try VocabularyPersistenceRow(record: .init(table: record.table, id: record.id,
            parentID: record.parentID, position: position, payload: record.payload, extra: record.extra))
        keyed[key] = row; delta.repositioned.append(row)
    }

    private static func root(_ row: VocabularyPersistenceRow, rows: VocabularyProjectionMap<Key, VocabularyPersistenceRow>) throws -> Key? {
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

    private static func isClassification(_ entity: VocabularyPersistenceEntity) -> Bool {
        switch entity {
        case .classificationFrameworks, .categories, .categoryParents, .categoryMemberships, .categoryOverrides: true
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
    public let repositioned: [VocabularyPersistenceRow]
}
