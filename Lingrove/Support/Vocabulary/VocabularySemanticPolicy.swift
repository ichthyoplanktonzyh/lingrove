import Foundation

/// Pure integrity and edit rules for the meaning graph. The archive invokes these before a
/// transaction; UI drafts can be discarded without touching durable identities or examples.
nonisolated enum VocabularySemanticPolicy {
    static func validate(_ index: VocabularySemanticIndex, entries: [VocabularyEntry]) throws {
        guard index.nodes.count <= 100_000, index.mappings.count <= 500_000,
              index.patterns.count <= 500_000, index.relations.count <= 500_000,
              index.cues.count <= 500_000, index.cueTargets.count <= 500_000 else { throw VocabularyError.invalidContent }
        var context = try ValidationContext(entries: entries)
        for node in index.nodes { try context.node(node) }
        for pattern in index.patterns { try context.pattern(pattern) }
        for mapping in index.mappings { try context.mapping(mapping) }
        for relation in index.relations { try context.relation(relation) }
        try validateHierarchy(index.relations)
        for cue in index.cues { try context.cue(cue) }
        for target in index.cueTargets { try context.cueTarget(target) }
    }

    /// One validation pass owns these temporary lookup tables. Building them in dependency
    /// order rejects duplicate IDs before dictionary construction and keeps validation linear
    /// in the number of records rather than repeatedly scanning the full notebook.
    private struct ValidationContext {
        var ids: Set<UUID>
        let senses: [UUID: VocabularySense]
        var nodes: [UUID: VocabularyMeaningNode] = [:]
        var patterns: [UUID: VocabularyUsagePattern] = [:]
        var cues: Set<UUID> = []
        var targets: Set<String> = []

        init(entries: [VocabularyEntry]) throws {
            let values = entries.flatMap(\.senses)
            guard Set(values.map(\.id)).count == values.count else { throw VocabularyError.invalidArchive }
            senses = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            ids = Set(entries.map(\.id) + values.map(\.id) + values.flatMap { $0.examples.map(\.id) })
        }
        mutating func identify(_ id: UUID) throws {
            guard ids.insert(id).inserted else { throw VocabularyError.invalidArchive }
        }
        func text(_ value: String, required: Bool = false) throws {
            guard value.utf8.count <= 32_768, !required || !VocabularyPolicy.normalized(value).isEmpty else {
                throw VocabularyError.invalidContent
            }
        }
        func provenance(_ value: VocabularySemanticProvenance) throws {
            try text(value.source)
            if let score = value.confidence {
                guard score.isFinite, (0...1).contains(score) else { throw VocabularyError.invalidContent }
            }
        }
        mutating func node(_ node: VocabularyMeaningNode) throws {
            try identify(node.id); try text(node.definition); try text(node.scopeNote); try provenance(node.provenance)
            guard !node.labels.isEmpty, node.labels.count <= 128, node.roles.count <= 64 else { throw VocabularyError.invalidContent }
            var languages = Set<String>()
            for label in node.labels {
                try identify(label.id); try text(label.text, required: true)
                if label.preferred {
                    guard languages.insert(label.language?.rawValue ?? "und").inserted else { throw VocabularyError.invalidContent }
                }
            }
            guard !languages.isEmpty else { throw VocabularyError.invalidContent }
            for role in node.roles { try identify(role.id); try text(role.name, required: true); try text(role.description) }
            nodes[node.id] = node
        }
        mutating func pattern(_ pattern: VocabularyUsagePattern) throws {
            try identify(pattern.id); try text(pattern.template, required: true); try text(pattern.note)
            try text(pattern.region); try provenance(pattern.provenance)
            guard senses[pattern.senseID] != nil, pattern.slots.count <= 64, pattern.collocations.count <= 128,
                  Set(pattern.slots.map { VocabularyPolicy.normalized($0.name) }).count == pattern.slots.count else {
                throw VocabularyError.invalidContent
            }
            for slot in pattern.slots { try identify(slot.id); try text(slot.name, required: true); try text(slot.constraint) }
            for value in pattern.collocations { try text(value, required: true) }
            patterns[pattern.id] = pattern
        }
        mutating func mapping(_ mapping: VocabularyMeaningMapping) throws {
            try identify(mapping.id); try text(mapping.conditions); try text(mapping.nuance); try provenance(mapping.provenance)
            guard let node = nodes[mapping.nodeID], let sense = senses[mapping.senseID],
                  (node.kind == .concept) == (mapping.relation == .expressesContent),
                  mapping.patternID.map({ patterns[$0]?.senseID == mapping.senseID }) ?? true,
                  Set(mapping.evidenceIDs).count == mapping.evidenceIDs.count,
                  Set(mapping.evidenceIDs).isSubset(of: Set(sense.examples.map(\.id))),
                  mapping.roleBindings.count <= 64 else { throw VocabularyError.invalidContent }
            let slots = mapping.patternID.flatMap { patterns[$0]?.slots } ?? []
            for binding in mapping.roleBindings {
                try identify(binding.id)
                guard node.roles.contains(where: { $0.id == binding.roleID }),
                      slots.contains(where: { $0.id == binding.slotID }) else { throw VocabularyError.invalidContent }
            }
            guard Set(mapping.roleBindings.map(\.roleID)).count == mapping.roleBindings.count else {
                throw VocabularyError.invalidContent
            }
        }
        mutating func relation(_ relation: VocabularyMeaningRelation) throws {
            try identify(relation.id); try text(relation.note); try provenance(relation.provenance)
            guard let source = nodes[relation.sourceID], let target = nodes[relation.targetID], source.id != target.id,
                  relation.kind == .related || source.kind == target.kind else { throw VocabularyError.invalidContent }
        }
        mutating func cue(_ cue: VocabularyRetrievalCue) throws {
            try identify(cue.id); try text(cue.text, required: true); cues.insert(cue.id)
        }
        mutating func cueTarget(_ target: VocabularyCueTarget) throws {
            try identify(target.id); try text(target.conditions); try provenance(target.provenance)
            guard cues.contains(target.cueID), nodes[target.nodeID] != nil,
                  targets.insert(target.cueID.uuidString + target.nodeID.uuidString).inserted else {
                throw VocabularyError.invalidContent
            }
        }
    }

    private static func validateHierarchy(_ relations: [VocabularyMeaningRelation]) throws {
        let hierarchy = relations.filter { $0.kind == .narrower }
        var children: [UUID: [UUID]] = [:], incoming: [UUID: Int] = [:]
        for edge in hierarchy {
            children[edge.sourceID, default: []].append(edge.targetID)
            incoming[edge.sourceID, default: 0] += 0
            incoming[edge.targetID, default: 0] += 1
        }
        var queue = incoming.filter { $0.value == 0 }.map(\.key), cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for child in children[id] ?? [] {
                incoming[child, default: 0] -= 1
                if incoming[child] == 0 { queue.append(child) }
            }
        }
        guard queue.count == incoming.count else { throw VocabularyError.invalidContent }
    }

    /// Merge each independently identified record, preserving edits to unrelated records made
    /// after a sheet opened. A concurrent change to the same record produces an explicit conflict.
    static func merge(_ edited: VocabularySemanticIndex, baseline: VocabularySemanticIndex,
                      current: VocabularySemanticIndex) throws -> VocabularySemanticIndex {
        .init(nodes: try mergeRows(edited.nodes, baseline.nodes, current.nodes),
              patterns: try mergeRows(edited.patterns, baseline.patterns, current.patterns),
              mappings: try mergeRows(edited.mappings, baseline.mappings, current.mappings),
              relations: try mergeRows(edited.relations, baseline.relations, current.relations),
              cues: try mergeRows(edited.cues, baseline.cues, current.cues),
              cueTargets: try mergeRows(edited.cueTargets, baseline.cueTargets, current.cueTargets))
    }

    private static func mergeRows<T: Identifiable & Equatable>(_ edited: [T], _ baseline: [T], _ current: [T]) throws -> [T]
        where T.ID == UUID {
        guard Set(edited.map(\.id)).count == edited.count else { throw VocabularyError.invalidContent }
        var result = current
        for value in edited {
            let before = baseline.first { $0.id == value.id }
            guard before != value else { continue }
            if let position = result.firstIndex(where: { $0.id == value.id }) {
                guard result[position] == before || result[position] == value else { throw VocabularyError.editConflict }
                result[position] = value
            } else {
                guard before == nil else { throw VocabularyError.editConflict }
                result.append(value)
            }
        }
        for before in baseline where !edited.contains(where: { $0.id == before.id }) {
            if let value = result.first(where: { $0.id == before.id }), value != before { throw VocabularyError.editConflict }
            result.removeAll { $0.id == before.id }
        }
        return result
    }

    /// Lexical deletion/merge already owns the transaction. Reconcile only previously valid
    /// references affected by that operation; malformed imported references must still fail
    /// validation rather than being silently discarded. Moving evidence does not move a claim.
    static func reconcile(_ index: inout VocabularySemanticIndex, previous: VocabularyDocument,
                          entries: [VocabularyEntry]) {
        let previousEntries = previous.entries
        let oldSenses = Set(previousEntries.flatMap { $0.senses.map(\.id) })
        let senses = entries.flatMap(\.senses)
        let live = Set(senses.map(\.id))
        var aliases: [UUID: UUID] = [:]
        for sense in senses { for alias in sense.mergedFrom { aliases[alias] = sense.id } }
        func resolved(_ id: UUID) -> UUID? { live.contains(id) ? id : aliases[id] ?? (oldSenses.contains(id) ? nil : id) }
        index.patterns = index.patterns.compactMap { value in
            guard let id = resolved(value.senseID) else { return nil }
            var value = value; value.senseID = id; return value
        }
        let removedPatterns = Set(previous.semantics.patterns.map(\.id)).subtracting(index.patterns.map(\.id))
        let oldEvidence = Set(previousEntries.flatMap { $0.examples.map(\.id) })
        let previousExamples = Dictionary(uniqueKeysWithValues: previousEntries.flatMap(\.examples).map { ($0.id, $0) })
        let changedEvidence = Set(senses.flatMap(\.examples).compactMap { example -> UUID? in
            guard let before = previousExamples[example.id] else { return nil }
            // An interpretation keeps its editor identity when its source is corrected. A
            // previously confirmed mapping must not silently cite the replacement occurrence.
            // Translation/annotation-only edits do not change the linguistic evidence.
            let changed = before.sourceID != example.sourceID || before.occurrenceID != example.occurrenceID ||
                before.text != example.text || before.ranges != example.ranges ||
                before.meaning != example.meaning || before.meaningLanguage != example.meaningLanguage
            return changed ? example.id : nil
        })
        let evidenceBySense = Dictionary(uniqueKeysWithValues: senses.map { ($0.id, Set($0.examples.map(\.id))) })
        index.mappings = index.mappings.compactMap { value in
            guard let id = resolved(value.senseID), !(value.patternID.map({ removedPatterns.contains($0) }) ?? false) else { return nil }
            var value = value; value.senseID = id
            let validEvidence = evidenceBySense[id] ?? []
            let before = value.evidenceIDs
            value.evidenceIDs.removeAll {
                changedEvidence.contains($0) || (oldEvidence.contains($0) && !validEvidence.contains($0))
            }
            if value.evidenceIDs != before { value.provenance.status = .proposed }
            return value
        }
    }

    static func removeNode(_ id: UUID, from index: inout VocabularySemanticIndex) {
        index.nodes.removeAll { $0.id == id }
        index.mappings.removeAll { $0.nodeID == id }
        index.relations.removeAll { $0.sourceID == id || $0.targetID == id }
        index.cueTargets.removeAll { $0.nodeID == id }
    }

    /// A node editor may rename its cue, but another node may still use the original phrase.
    /// Fork shared records on change; preserve unchanged IDs, languages and target conditions.
    static func replaceCues(_ cues: [VocabularyRetrievalCue], for nodeID: UUID, in index: inout VocabularySemanticIndex) {
        let oldTargets = index.cueTargets.filter { $0.nodeID == nodeID }
        index.cueTargets.removeAll { $0.nodeID == nodeID }
        for draft in cues {
            var cue = draft
            if let old = index.cues.first(where: { $0.id == cue.id }), old != cue,
               index.cueTargets.contains(where: { $0.cueID == cue.id }) { cue.id = UUID() }
            if let offset = index.cues.firstIndex(where: { $0.id == cue.id }) {
                index.cues[offset] = cue
            } else { index.cues.append(cue) }
            var target = oldTargets.first { $0.cueID == draft.id } ?? .init(cueID: cue.id, nodeID: nodeID)
            target.cueID = cue.id
            index.cueTargets.append(target)
        }
    }

    static func removePattern(_ id: UUID, from index: inout VocabularySemanticIndex) {
        index.patterns.removeAll { $0.id == id }
        index.mappings.removeAll { $0.patternID == id }
    }

    /// Portable exports include only claims whose senses are selected. Evidence is omitted
    /// when examples are omitted, and graph expansion never pulls unselected private entries
    /// into an export merely because they share a meaning or an ambiguous search cue.
    static func selected(_ index: VocabularySemanticIndex, entries: [VocabularyEntry], examples: Bool) -> VocabularySemanticIndex {
        let senses = Set(entries.flatMap { $0.senses.map(\.id) })
        var result = index
        result.patterns.removeAll { !senses.contains($0.senseID) }
        result.mappings.removeAll { !senses.contains($0.senseID) }
        let exportedEvidence = examples ? Set(entries.flatMap { $0.examples.map(\.id) }) : []
        for offset in result.mappings.indices {
            result.mappings[offset].evidenceIDs.removeAll { !exportedEvidence.contains($0) }
        }
        let nodes = Set(result.mappings.map(\.nodeID))
        result.nodes.removeAll { !nodes.contains($0.id) }
        result.relations.removeAll { !nodes.contains($0.sourceID) || !nodes.contains($0.targetID) }
        result.cueTargets.removeAll { !nodes.contains($0.nodeID) }
        let cues = Set(result.cueTargets.map(\.cueID))
        result.cues.removeAll { !cues.contains($0.id) }
        return result
    }
}
