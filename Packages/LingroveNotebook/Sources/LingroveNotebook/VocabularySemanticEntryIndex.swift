import Foundation

/// A checked entry command can only retire patterns/mappings or retract cited evidence. This
/// immutable proof is created inside the domain module, then consumed by the row codec. It
/// cannot introduce graph identities, endpoints, hierarchy edges or role bindings; those
/// operations still require the full graph validator. One save owns the proof until commit.
public nonisolated struct VocabularySemanticEntryChange: Sendable {
    public let removedPatternIDs: Set<UUID>
    public let removedMappingIDs: Set<UUID>
    public let updatedMappings: [VocabularyMeaningMapping]
    let removedIdentifiers: Set<UUID>
    public var isEmpty: Bool {
        removedPatternIDs.isEmpty && removedMappingIDs.isEmpty && updatedMappings.isEmpty
    }

    static let empty = Self(removedPatternIDs: [], removedMappingIDs: [], updatedMappings: [], removedIdentifiers: [])

    func combining(_ next: Self) -> Self {
        let removed = removedMappingIDs.union(next.removedMappingIDs)
        var values = Dictionary(uniqueKeysWithValues: updatedMappings.map { ($0.id, $0) })
        for value in next.updatedMappings { values[value.id] = value }
        for id in removed { values.removeValue(forKey: id) }
        return .init(removedPatternIDs: removedPatternIDs.union(next.removedPatternIDs), removedMappingIDs: removed,
            updatedMappings: values.values.sorted { $0.id.uuidString < $1.id.uuidString },
            removedIdentifiers: removedIdentifiers.union(next.removedIdentifiers))
    }
}

/// The validated save state owns this reverse index beside its graph. Lookups find only the
/// patterns/mappings depending on changed senses/evidence. The unchanged graph's proof remains
/// valid because entry reconciliation only removes constraints and marks surviving citations
/// proposed. Arrays are compacted to preserve their existing order; unrelated records are not
/// revalidated or encoded. Arbitrary organization/import edits rebuild this derived index.
nonisolated struct VocabularySemanticEntryIndex: Sendable {
    private var patterns: [UUID: VocabularyUsagePattern]
    private var mappings: [UUID: VocabularyMeaningMapping]
    private var patternsBySense: [UUID: Set<UUID>] = [:]
    private var mappingsBySense: [UUID: Set<UUID>] = [:]
    private var mappingsByPattern: [UUID: Set<UUID>] = [:]
    private var mappingsByEvidence: [UUID: Set<UUID>] = [:]

    init(_ graph: VocabularySemanticIndex) {
        patterns = Dictionary(uniqueKeysWithValues: graph.patterns.map { ($0.id, $0) })
        mappings = Dictionary(uniqueKeysWithValues: graph.mappings.map { ($0.id, $0) })
        for value in graph.patterns { patternsBySense[value.senseID, default: []].insert(value.id) }
        for value in graph.mappings { index(value) }
    }

    func reconciling(_ graph: inout VocabularySemanticIndex, previous: VocabularyEntry?, current: VocabularyEntry?)
        -> (Self, VocabularySemanticEntryChange) {
        let old = previous?.senses ?? [], new = current?.senses ?? []
        let retired = Set(old.map(\.id)).subtracting(new.map(\.id))
        let examples = Dictionary(uniqueKeysWithValues: new.flatMap { sense in sense.examples.map { ($0.id, (sense.id, $0)) } })
        var invalid = Set<UUID>()
        for sense in old {
            for before in sense.examples {
                guard let (owner, after) = examples[before.id], owner == sense.id else { invalid.insert(before.id); continue }
                if before.sourceID != after.sourceID || before.occurrenceID != after.occurrenceID ||
                    before.text != after.text || before.ranges != after.ranges ||
                    before.meaning != after.meaning || before.meaningLanguage != after.meaningLanguage {
                    invalid.insert(before.id)
                }
            }
        }
        guard !retired.isEmpty || !invalid.isEmpty else { return (self, .empty) }
        let removedPatterns = retired.reduce(into: Set<UUID>()) { $0.formUnion(patternsBySense[$1] ?? []) }
        var removedMappings = retired.reduce(into: Set<UUID>()) { $0.formUnion(mappingsBySense[$1] ?? []) }
        for id in removedPatterns { removedMappings.formUnion(mappingsByPattern[id] ?? []) }
        let affected = invalid.reduce(into: Set<UUID>()) { $0.formUnion(mappingsByEvidence[$1] ?? []) }
        var next = self, identifiers = Set<UUID>(), updates: [VocabularyMeaningMapping] = []
        for id in removedPatterns {
            guard let value = next.patterns.removeValue(forKey: id) else { continue }
            identifiers.insert(id); identifiers.formUnion(value.slots.map(\.id))
            next.patternsBySense[value.senseID]?.remove(id)
        }
        for id in removedMappings {
            guard let value = next.mappings.removeValue(forKey: id) else { continue }
            identifiers.insert(id); identifiers.formUnion(value.roleBindings.map(\.id))
            next.unindex(value)
        }
        for id in affected.subtracting(removedMappings) {
            guard var value = next.mappings[id] else { continue }
            next.unindex(value)
            value.evidenceIDs.removeAll { invalid.contains($0) }
            value.provenance.status = .proposed
            next.mappings[id] = value; next.index(value); updates.append(value)
        }
        let change = VocabularySemanticEntryChange(removedPatternIDs: removedPatterns, removedMappingIDs: removedMappings,
            updatedMappings: updates, removedIdentifiers: identifiers)
        guard !change.isEmpty else { return (self, .empty) }
        if !removedPatterns.isEmpty { graph.patterns.removeAll { removedPatterns.contains($0.id) } }
        let replacements = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
        graph.mappings = graph.mappings.compactMap { value in
            removedMappings.contains(value.id) ? nil : replacements[value.id] ?? value
        }
        return (next, change)
    }

    private mutating func index(_ value: VocabularyMeaningMapping) {
        mappingsBySense[value.senseID, default: []].insert(value.id)
        if let id = value.patternID { mappingsByPattern[id, default: []].insert(value.id) }
        for id in value.evidenceIDs { mappingsByEvidence[id, default: []].insert(value.id) }
    }

    private mutating func unindex(_ value: VocabularyMeaningMapping) {
        mappingsBySense[value.senseID]?.remove(value.id)
        if let id = value.patternID { mappingsByPattern[id]?.remove(value.id) }
        for id in value.evidenceIDs { mappingsByEvidence[id]?.remove(value.id) }
    }
}
