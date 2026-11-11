import Foundation

/// The wire keeps legacy rank/array fields, but unordered corpus membership cannot create
/// an edit merely by permuting a JSON container. Confirmed values retain their exact shape;
/// genuine additions use the existing add/reset clocks rather than a new merge protocol.
nonisolated enum VocabularyWireMembership {
    static func unorderedArray(_ kind: VocabularyWireEntityKind, _ field: String) -> Bool {
        switch kind {
        case .sense: ["tags", "mergedFrom", "standaloneMeanings", "alternateMeanings"].contains(field)
        case .interpretation: field == "translationVariants"
        case .usagePattern: field == "collocations"
        default: false
        }
    }

    static func contains(_ values: [VocabularyWireJSON], _ subset: [VocabularyWireJSON]) -> Bool {
        var remaining = values
        for value in subset {
            guard let offset = remaining.firstIndex(where: { $0.hasSameWireValue(as: value) }) else { return false }
            remaining.remove(at: offset)
        }
        return true
    }

    static func same(_ lhs: VocabularyWireJSON?, _ rhs: VocabularyWireJSON?, kind: VocabularyWireEntityKind, field: String) -> Bool {
        if unorderedArray(kind, field), case let .array(left)? = lhs, case let .array(right)? = rhs {
            return left.count == right.count && contains(left, right)
        }
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return left.hasSameWireValue(as: right)
        default: return false
        }
    }

    static func retainingConfirmedFields(_ entities: [VocabularyWireEntity], from baseline: [VocabularyWireEntity]) -> [VocabularyWireEntity] {
        let old = Dictionary(uniqueKeysWithValues: baseline.map { ($0.entityType.rawValue + ":" + $0.entityID, $0) })
        return entities.map { entity in
            guard let previous = old[entity.entityType.rawValue + ":" + entity.entityID] else { return entity }
            var fields = entity.fields
            if !entity.entityType.hasBusinessOrder { fields["rank"] = previous.fields["rank"] }
            for (field, value) in fields where unorderedArray(entity.entityType, field) {
                guard case let .array(before)? = previous.fields[field], case let .array(after) = value,
                      contains(after, before) else { continue }
                var remaining = after
                for value in before {
                    if let offset = remaining.firstIndex(where: { $0.hasSameWireValue(as: value) }) { remaining.remove(at: offset) }
                }
                fields[field] = .array(before + remaining)
            }
            return .init(entityType: entity.entityType, entityID: entity.entityID, fields: fields)
        }
    }
}
