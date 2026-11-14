import Foundation

/// Corpus membership is identified by stable identity, not an array offset. These pure rules
/// are shared by domain equality, persistence and wire adapters. Arrays remain convenient
/// transport/display containers; this module does not deduplicate content or choose a primary
/// sense. Ordered authored blocks and source UTF-16 spans keep ordinary sequence equality.
public nonisolated enum VocabularyMembershipPolicy {
    public static func same<T: Identifiable & Equatable>(_ lhs: [T], _ rhs: [T]) -> Bool where T.ID: Hashable {
        guard lhs.count == rhs.count else { return false }
        if zip(lhs, rhs).allSatisfy({ $0.id == $1.id && $0 == $1 }) { return true }
        var values: [T.ID: T] = [:]
        for value in lhs {
            guard values.updateValue(value, forKey: value.id) == nil else { return false }
        }
        for value in rhs {
            guard values.removeValue(forKey: value.id) == value else { return false }
        }
        return values.isEmpty
    }

    public static func sameValues<T: Hashable>(_ lhs: [T], _ rhs: [T]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs == rhs { return true }
        var counts: [T: Int] = [:]
        for value in lhs { counts[value, default: 0] += 1 }
        for value in rhs {
            guard let count = counts[value], count > 0 else { return false }
            counts[value] = count - 1
        }
        return true
    }

    public static func sameMeanings(_ lhs: [VocabularyMeaning], _ rhs: [VocabularyMeaning]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.sorted(by: meaningOrder) == rhs.sorted(by: meaningOrder)
    }

    public static func meaningOrder(_ lhs: VocabularyMeaning, _ rhs: VocabularyMeaning) -> Bool {
        let left = lhs.language?.rawValue ?? "", right = rhs.language?.rawValue ?? ""
        return left == right ? lhs.text.utf8.lexicographicallyPrecedes(rhs.text.utf8) : left < right
    }

    /// Defaults are explicit presentation/creation rules. A saved review still stores its
    /// selected example ID; a display reorder cannot replace that source or change the question.
    public static func defaultSense(in entry: VocabularyEntry) -> VocabularySense? {
        entry.senses.min { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    public static func defaultExample(in sense: VocabularySense) -> VocabularyExample? {
        sense.examples.min { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
}

public extension VocabularyEntry {
    /// Stable display/default selection has no durable priority or ordering authority.
    var presentationSenses: [VocabularySense] {
        senses.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    var defaultSense: VocabularySense? { VocabularyMembershipPolicy.defaultSense(in: self) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.id == rhs.id,
              lhs.expression == rhs.expression,
              lhs.dictionaryForm == rhs.dictionaryForm,
              lhs.language == rhs.language else { return false }
        guard lhs.kind == rhs.kind,
              VocabularyMembershipPolicy.same(lhs.senses, rhs.senses),
              lhs.createdAt == rhs.createdAt,
              lhs.updatedAt == rhs.updatedAt else { return false }
        return true
    }
}

public extension VocabularySense {
    var presentationExamples: [VocabularyExample] {
        examples.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    var defaultExample: VocabularyExample? { VocabularyMembershipPolicy.defaultExample(in: self) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.id == rhs.id,
              lhs.meaning == rhs.meaning,
              lhs.meaningLanguage == rhs.meaningLanguage,
              lhs.meaningOrigin == rhs.meaningOrigin else { return false }
        guard lhs.note == rhs.note,
              VocabularyMembershipPolicy.sameValues(lhs.tags, rhs.tags),
              VocabularyMembershipPolicy.same(lhs.examples, rhs.examples),
              lhs.isSavedWithoutContext == rhs.isSavedWithoutContext else { return false }
        guard VocabularyMembershipPolicy.sameMeanings(lhs.standaloneMeanings, rhs.standaloneMeanings),
              lhs.explanations == rhs.explanations,
              VocabularyMembershipPolicy.sameMeanings(lhs.alternateMeanings, rhs.alternateMeanings),
              VocabularyMembershipPolicy.sameValues(lhs.mergedFrom, rhs.mergedFrom) else { return false }
        guard lhs.content == rhs.content,
              lhs.savedAt == rhs.savedAt else { return false }
        guard lhs.createdAt == rhs.createdAt,
              lhs.updatedAt == rhs.updatedAt,
              lhs.createdWithoutContext == rhs.createdWithoutContext else { return false }
        return true
    }
}

public extension VocabularyExample {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.id == rhs.id,
              lhs.sourceID == rhs.sourceID,
              lhs.occurrenceID == rhs.occurrenceID,
              lhs.sourceKind == rhs.sourceKind else { return false }
        guard lhs.text == rhs.text,
              lhs.translation == rhs.translation,
              lhs.translationLanguage == rhs.translationLanguage,
              VocabularyMembershipPolicy.sameMeanings(lhs.translationVariants, rhs.translationVariants) else { return false }
        guard lhs.ranges == rhs.ranges,
              lhs.completeness == rhs.completeness,
              lhs.meaning == rhs.meaning,
              lhs.meaningLanguage == rhs.meaningLanguage else { return false }
        guard lhs.meaningOrigin == rhs.meaningOrigin,
              lhs.appBundleIdentifier == rhs.appBundleIdentifier,
              lhs.createdAt == rhs.createdAt,
              lhs.explanations == rhs.explanations else { return false }
        return true
    }
}

public extension VocabularyDocument {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.schemaVersion == rhs.schemaVersion,
              VocabularyMembershipPolicy.same(lhs.catalog, rhs.catalog),
              VocabularyMembershipPolicy.same(lhs.sources, rhs.sources),
              VocabularyMembershipPolicy.same(lhs.occurrences, rhs.occurrences) else { return false }
        guard VocabularyMembershipPolicy.same(lhs.interpretations, rhs.interpretations),
              lhs.semantics == rhs.semantics,
              lhs.classification == rhs.classification else { return false }
        return true
    }
}

public extension VocabularySemanticIndex {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard VocabularyMembershipPolicy.same(lhs.nodes, rhs.nodes),
              VocabularyMembershipPolicy.same(lhs.patterns, rhs.patterns),
              VocabularyMembershipPolicy.same(lhs.mappings, rhs.mappings),
              VocabularyMembershipPolicy.same(lhs.relations, rhs.relations) else { return false }
        guard VocabularyMembershipPolicy.same(lhs.cues, rhs.cues),
              VocabularyMembershipPolicy.same(lhs.cueTargets, rhs.cueTargets) else { return false }
        return true
    }
}

public extension VocabularyMeaningNode {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.id == rhs.id,
              lhs.kind == rhs.kind,
              VocabularyMembershipPolicy.same(lhs.labels, rhs.labels),
              lhs.definition == rhs.definition else { return false }
        guard lhs.scopeNote == rhs.scopeNote,
              VocabularyMembershipPolicy.same(lhs.roles, rhs.roles),
              lhs.provenance == rhs.provenance,
              lhs.createdAt == rhs.createdAt else { return false }
        guard lhs.updatedAt == rhs.updatedAt else { return false }
        return true
    }
}

public extension VocabularyUsagePattern {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.id == rhs.id,
              lhs.senseID == rhs.senseID,
              lhs.template == rhs.template,
              VocabularyMembershipPolicy.same(lhs.slots, rhs.slots) else { return false }
        guard lhs.formality == rhs.formality,
              lhs.medium == rhs.medium,
              lhs.region == rhs.region,
              lhs.note == rhs.note else { return false }
        guard VocabularyMembershipPolicy.sameValues(lhs.collocations, rhs.collocations),
              lhs.provenance == rhs.provenance else { return false }
        return true
    }
}

public extension VocabularyMeaningMapping {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.id == rhs.id,
              lhs.nodeID == rhs.nodeID,
              lhs.senseID == rhs.senseID,
              lhs.patternID == rhs.patternID else { return false }
        guard lhs.relation == rhs.relation,
              lhs.conditions == rhs.conditions,
              lhs.nuance == rhs.nuance,
              VocabularyMembershipPolicy.same(lhs.roleBindings, rhs.roleBindings) else { return false }
        guard VocabularyMembershipPolicy.sameValues(lhs.evidenceIDs, rhs.evidenceIDs),
              lhs.provenance == rhs.provenance else { return false }
        return true
    }
}

public extension VocabularyClassificationIndex {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard VocabularyMembershipPolicy.same(lhs.frameworks, rhs.frameworks),
              VocabularyMembershipPolicy.same(lhs.categories, rhs.categories),
              VocabularyMembershipPolicy.same(lhs.parents, rhs.parents),
              VocabularyMembershipPolicy.same(lhs.memberships, rhs.memberships) else { return false }
        guard VocabularyMembershipPolicy.same(lhs.overrides, rhs.overrides) else { return false }
        return true
    }
}

public extension VocabularyInterpretation {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.id == rhs.id else { return false }
        guard lhs.occurrenceID == rhs.occurrenceID else { return false }
        guard lhs.senseID == rhs.senseID else { return false }
        guard lhs.status == rhs.status else { return false }
        guard lhs.meaning == rhs.meaning else { return false }
        guard lhs.meaningLanguage == rhs.meaningLanguage else { return false }
        guard lhs.meaningOrigin == rhs.meaningOrigin else { return false }
        guard lhs.translation == rhs.translation else { return false }
        guard lhs.translationLanguage == rhs.translationLanguage else { return false }
        guard VocabularyMembershipPolicy.sameMeanings(lhs.translationVariants, rhs.translationVariants) else { return false }
        guard lhs.completeness == rhs.completeness else { return false }
        guard lhs.provenance == rhs.provenance else { return false }
        guard lhs.explanations == rhs.explanations else { return false }
        guard lhs.createdAt == rhs.createdAt else { return false }
        return true
    }
}
