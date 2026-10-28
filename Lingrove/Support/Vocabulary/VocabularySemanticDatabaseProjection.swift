import Foundation

/// The semantic half of the relational projection keeps graph foreign keys in SQL columns.
/// Small payloads contain only one record's leaf data; labels, slots, evidence and links are
/// separate rows so changing a definition never rewrites its expressions or original excerpts.
nonisolated enum VocabularySemanticDatabaseProjection {
    typealias Row = VocabularyDatabaseRecord

    // Keep the typed table dispatch exhaustive; each case describes an independent row format.
    // swiftlint:disable:next cyclomatic_complexity
    static func rows(_ index: VocabularySemanticIndex) -> [Row] {
        var rows: [Row] = []
        for (position, node) in index.nodes.enumerated() {
            var header = node; header.labels = []; header.roles = []
            rows.append(.init(table: .meaningNodes, id: node.id.uuidString, parentID: nil, position: position,
                payload: .meaningNode(header), extra: [node.kind.rawValue]))
            for (offset, label) in node.labels.enumerated() {
                rows.append(.init(table: .meaningLabels, id: label.id.uuidString, parentID: node.id.uuidString, position: offset,
                    payload: .meaningLabel(label), extra: [label.language?.rawValue ?? "und", label.text, label.preferred ? "yes" : "no"]))
            }
            for (offset, role) in node.roles.enumerated() {
                rows.append(.init(table: .meaningRoles, id: role.id.uuidString, parentID: node.id.uuidString, position: offset,
                    payload: .meaningRole(role), extra: [role.name]))
            }
        }
        for (position, pattern) in index.patterns.enumerated() {
            var header = pattern; header.slots = []
            rows.append(.init(table: .usagePatterns, id: pattern.id.uuidString, parentID: pattern.senseID.uuidString,
                position: position, payload: .usagePattern(header), extra: [pattern.template]))
            for (offset, slot) in pattern.slots.enumerated() {
                rows.append(.init(table: .patternSlots, id: slot.id.uuidString, parentID: pattern.id.uuidString, position: offset,
                    payload: .patternSlot(slot), extra: [slot.name]))
            }
        }
        for (position, mapping) in index.mappings.enumerated() {
            var header = mapping; header.roleBindings = []; header.evidenceIDs = []
            rows.append(.init(table: .meaningMappings, id: mapping.id.uuidString, parentID: mapping.senseID.uuidString,
                position: position, payload: .meaningMapping(header),
                extra: [mapping.nodeID.uuidString, mapping.patternID?.uuidString, mapping.relation.rawValue]))
            for (offset, binding) in mapping.roleBindings.enumerated() {
                rows.append(.init(table: .mappingRoles, id: binding.id.uuidString, parentID: mapping.id.uuidString,
                    position: offset, payload: .roleBinding(binding), extra: [binding.roleID.uuidString, binding.slotID.uuidString]))
            }
            for (offset, evidence) in mapping.evidenceIDs.enumerated() {
                rows.append(.init(table: .mappingEvidence, id: mapping.id.uuidString + ":" + evidence.uuidString,
                    parentID: mapping.id.uuidString, position: offset, payload: .evidence(evidence), extra: [evidence.uuidString]))
            }
        }
        for (position, relation) in index.relations.enumerated() {
            rows.append(.init(table: .meaningRelations, id: relation.id.uuidString, parentID: relation.sourceID.uuidString,
                position: position, payload: .meaningRelation(relation), extra: [relation.targetID.uuidString, relation.kind.rawValue]))
        }
        for (position, cue) in index.cues.enumerated() {
            rows.append(.init(table: .retrievalCues, id: cue.id.uuidString, parentID: nil, position: position,
                payload: .retrievalCue(cue), extra: [cue.language?.rawValue ?? "und", cue.text]))
        }
        for (position, target) in index.cueTargets.enumerated() {
            rows.append(.init(table: .cueTargets, id: target.id.uuidString, parentID: target.cueID.uuidString,
                position: position, payload: .cueTarget(target), extra: [target.nodeID.uuidString]))
        }
        return rows
    }

    // Keep the typed table dispatch exhaustive; each case describes an independent row format.
    // swiftlint:disable:next cyclomatic_complexity
    static func index(_ rows: [Row]) throws -> VocabularySemanticIndex {
        let tables = Dictionary(grouping: rows, by: \.table)
        func records<T>(_ table: Row.Table, parent: UUID? = nil, value: (Row.Payload) -> T?) throws -> [T] {
            let records = (tables[table] ?? []).filter { parent == nil || $0.parentID == parent?.uuidString }
                .sorted { $0.position < $1.position }
            guard records.map(\.position) == Array(records.indices) else { throw VocabularyError.invalidArchive }
            return try records.map { row in
                guard let result = value(row.payload) else { throw VocabularyError.invalidArchive }; return result
            }
        }
        var index = VocabularySemanticIndex()
        index.nodes = try records(.meaningNodes) { if case let .meaningNode(value) = $0 { value } else { nil } }
        for offset in index.nodes.indices {
            let id = index.nodes[offset].id
            index.nodes[offset].labels = try records(.meaningLabels, parent: id) {
                if case let .meaningLabel(value) = $0 { value } else { nil }
            }
            index.nodes[offset].roles = try records(.meaningRoles, parent: id) {
                if case let .meaningRole(value) = $0 { value } else { nil }
            }
        }
        index.patterns = try records(.usagePatterns) { if case let .usagePattern(value) = $0 { value } else { nil } }
        for offset in index.patterns.indices {
            index.patterns[offset].slots = try records(.patternSlots, parent: index.patterns[offset].id) {
                if case let .patternSlot(value) = $0 { value } else { nil }
            }
        }
        index.mappings = try records(.meaningMappings) { if case let .meaningMapping(value) = $0 { value } else { nil } }
        for offset in index.mappings.indices {
            let id = index.mappings[offset].id
            index.mappings[offset].roleBindings = try records(.mappingRoles, parent: id) {
                if case let .roleBinding(value) = $0 { value } else { nil }
            }
            index.mappings[offset].evidenceIDs = try records(.mappingEvidence, parent: id) {
                if case let .evidence(value) = $0 { value } else { nil }
            }
        }
        index.relations = try records(.meaningRelations) { if case let .meaningRelation(value) = $0 { value } else { nil } }
        index.cues = try records(.retrievalCues) { if case let .retrievalCue(value) = $0 { value } else { nil } }
        index.cueTargets = try records(.cueTargets) { if case let .cueTarget(value) = $0 { value } else { nil } }
        return index
    }
}
