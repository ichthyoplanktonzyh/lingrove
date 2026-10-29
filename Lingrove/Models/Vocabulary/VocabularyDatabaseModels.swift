import Foundation

/// Typed rows separate durable relationships from flexible leaf values. The archive's SQLite
/// implementation owns these projections; no SQL handle or storage representation reaches UI.
nonisolated struct VocabularyDatabaseRecord: Equatable, Sendable {
    enum Table: String, CaseIterable, Sendable {
        case entries, senses, sources, occurrences, usages, collections
        case collectionInterpretations = "collection_interpretations"
        case senseExplanations = "sense_explanations", usageExplanations = "usage_explanations"
        case blocks, reviews, bindings, templates
        case meaningNodes = "meaning_nodes", meaningLabels = "meaning_labels", meaningRoles = "meaning_roles"
        case usagePatterns = "usage_patterns", patternSlots = "pattern_slots", meaningMappings = "meaning_mappings"
        case mappingRoles = "mapping_roles", mappingEvidence = "mapping_evidence", meaningRelations = "meaning_relations"
        case retrievalCues = "retrieval_cues", cueTargets = "cue_targets"
        case classificationFrameworks = "classification_frameworks", categories
        case categoryParents = "category_parents", categoryMemberships = "category_memberships", categoryOverrides = "category_overrides"

        var parent: Self? {
            switch self {
            case .entries, .templates, .meaningNodes, .retrievalCues, .sources, .usages, .collections: nil
            case .classificationFrameworks, .categories, .categoryParents, .categoryMemberships: nil
            case .categoryOverrides: .categories
            case .occurrences: .sources
            case .senses: .entries
            case .senseExplanations: .senses
            case .blocks, .reviews, .collectionInterpretations: .collections
            case .usageExplanations: .usages
            case .bindings: .reviews
            case .meaningLabels, .meaningRoles, .meaningRelations: .meaningNodes
            case .usagePatterns, .meaningMappings: .senses
            case .patternSlots: .usagePatterns
            case .mappingRoles, .mappingEvidence: .meaningMappings
            case .cueTargets: .retrievalCues
            }
        }
        var extraColumns: [String] {
            switch self {
            case .classificationFrameworks: ["catalog_key"]
            case .categories: ["framework_id", "catalog_key", "axis"]
            case .categoryParents: ["category_id", "parent_category_id"]
            case .categoryMemberships: ["meaning_id", "category_id"]
            case .entries: ["lookup_key", "language", "expression"]
            case .senses: ["meaning"]
            case .usages: ["occurrence_id", "sense_id", "status"]
            case .collections: ["sense_id"]
            case .collectionInterpretations: ["usage_id"]
            case .meaningNodes: ["kind"]
            case .meaningLabels: ["language", "text", "preferred"]
            case .meaningRoles, .patternSlots: ["name"]
            case .usagePatterns: ["template"]
            case .meaningMappings: ["meaning_id", "pattern_id", "relation"]
            case .mappingRoles: ["role_id", "slot_id"]
            case .mappingEvidence: ["usage_id"]
            case .meaningRelations: ["target_id", "relation"]
            case .retrievalCues: ["language", "text"]
            case .cueTargets: ["meaning_id"]
            default: []
            }
        }
    }

    struct Key: Hashable, Sendable { let table: Table; let id: String }

    /// JSON is restricted to one entity's scalar/leaf fields. Relationships and ordering live
    /// in SQL columns, while stripping children prevents a note edit from rewriting its usages.
    enum Payload: Equatable, Sendable {
        case entry(VocabularyEntry), sense(VocabularySense), usage(VocabularyInterpretation), collection(VocabularyCollectionItem)
        case source(VocabularySourceSnapshot), occurrence(VocabularySourceOccurrence)
        case explanation(LearningExplanationRecord), block(VocabularyContentBlock)
        case review(VocabularyReview), binding(AnkiNoteBinding), template(ReviewLayoutTemplate)
        case meaningNode(VocabularyMeaningNode), meaningLabel(VocabularyMeaningLabel), meaningRole(VocabularyMeaningRole)
        case usagePattern(VocabularyUsagePattern), patternSlot(VocabularyPatternSlot), meaningMapping(VocabularyMeaningMapping)
        case roleBinding(VocabularyRoleBinding), evidence(UUID), meaningRelation(VocabularyMeaningRelation)
        case retrievalCue(VocabularyRetrievalCue), cueTarget(VocabularyCueTarget)
        case classificationFramework(VocabularyClassificationFramework), category(VocabularyCategory)
        case categoryParent(VocabularyCategoryParent), categoryMembership(VocabularyMeaningCategoryMembership)
        case categoryOverride(VocabularyCategoryOverride)

        // Keep the typed table dispatch exhaustive; each case describes an independent row format.
        // swiftlint:disable:next cyclomatic_complexity
        func encoded() throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            switch self {
            case let .classificationFramework(value): return try encoder.encode(value)
            case let .category(value): return try encoder.encode(value)
            case let .categoryParent(value): return try encoder.encode(value)
            case let .categoryMembership(value): return try encoder.encode(value)
            case let .categoryOverride(value): return try encoder.encode(value)
            case let .entry(value): return try encoder.encode(value)
            case let .sense(value): return try encoder.encode(value)
            case let .usage(value): return try encoder.encode(value)
            case let .collection(value): return try encoder.encode(value)
            case let .source(value): return try encoder.encode(value)
            case let .occurrence(value): return try encoder.encode(value)
            case let .explanation(value): return try encoder.encode(value)
            case let .block(value): return try encoder.encode(value)
            case let .review(value): return try encoder.encode(value)
            case let .binding(value): return try encoder.encode(value)
            case let .template(value): return try encoder.encode(value)
            case let .meaningNode(value): return try encoder.encode(value)
            case let .meaningLabel(value): return try encoder.encode(value)
            case let .meaningRole(value): return try encoder.encode(value)
            case let .usagePattern(value): return try encoder.encode(value)
            case let .patternSlot(value): return try encoder.encode(value)
            case let .meaningMapping(value): return try encoder.encode(value)
            case let .roleBinding(value): return try encoder.encode(value)
            case let .evidence(value): return try encoder.encode(value)
            case let .meaningRelation(value): return try encoder.encode(value)
            case let .retrievalCue(value): return try encoder.encode(value)
            case let .cueTarget(value): return try encoder.encode(value)
            }
        }

        // Keep the typed table dispatch exhaustive; each case describes an independent row format.
        // swiftlint:disable:next cyclomatic_complexity
        static func decode(_ bytes: Data, table: Table) throws -> Self {
            let decoder = JSONDecoder()
            switch table {
            case .classificationFrameworks:
                return .classificationFramework(try decoder.decode(VocabularyClassificationFramework.self, from: bytes))
            case .categories: return .category(try decoder.decode(VocabularyCategory.self, from: bytes))
            case .categoryParents: return .categoryParent(try decoder.decode(VocabularyCategoryParent.self, from: bytes))
            case .categoryMemberships:
                return .categoryMembership(try decoder.decode(VocabularyMeaningCategoryMembership.self, from: bytes))
            case .categoryOverrides: return .categoryOverride(try decoder.decode(VocabularyCategoryOverride.self, from: bytes))
            case .entries: return .entry(try decoder.decode(VocabularyEntry.self, from: bytes))
            case .senses: return .sense(try decoder.decode(VocabularySense.self, from: bytes))
            case .usages: return .usage(try decoder.decode(VocabularyInterpretation.self, from: bytes))
            case .collections: return .collection(try decoder.decode(VocabularyCollectionItem.self, from: bytes))
            case .collectionInterpretations: return .evidence(try decoder.decode(UUID.self, from: bytes))
            case .sources: return .source(try decoder.decode(VocabularySourceSnapshot.self, from: bytes))
            case .occurrences: return .occurrence(try decoder.decode(VocabularySourceOccurrence.self, from: bytes))
            case .senseExplanations, .usageExplanations:
                return .explanation(try decoder.decode(LearningExplanationRecord.self, from: bytes))
            case .blocks: return .block(try decoder.decode(VocabularyContentBlock.self, from: bytes))
            case .reviews: return .review(try decoder.decode(VocabularyReview.self, from: bytes))
            case .bindings: return .binding(try decoder.decode(AnkiNoteBinding.self, from: bytes))
            case .templates: return .template(try decoder.decode(ReviewLayoutTemplate.self, from: bytes))
            case .meaningNodes: return .meaningNode(try decoder.decode(VocabularyMeaningNode.self, from: bytes))
            case .meaningLabels: return .meaningLabel(try decoder.decode(VocabularyMeaningLabel.self, from: bytes))
            case .meaningRoles: return .meaningRole(try decoder.decode(VocabularyMeaningRole.self, from: bytes))
            case .usagePatterns: return .usagePattern(try decoder.decode(VocabularyUsagePattern.self, from: bytes))
            case .patternSlots: return .patternSlot(try decoder.decode(VocabularyPatternSlot.self, from: bytes))
            case .meaningMappings: return .meaningMapping(try decoder.decode(VocabularyMeaningMapping.self, from: bytes))
            case .mappingRoles: return .roleBinding(try decoder.decode(VocabularyRoleBinding.self, from: bytes))
            case .mappingEvidence: return .evidence(try decoder.decode(UUID.self, from: bytes))
            case .meaningRelations: return .meaningRelation(try decoder.decode(VocabularyMeaningRelation.self, from: bytes))
            case .retrievalCues: return .retrievalCue(try decoder.decode(VocabularyRetrievalCue.self, from: bytes))
            case .cueTargets: return .cueTarget(try decoder.decode(VocabularyCueTarget.self, from: bytes))
            }
        }
    }

    let table: Table
    let id: String
    let parentID: String?
    let position: Int
    let payload: Payload
    var extra: [String?] = []
    var key: Key { .init(table: table, id: id) }
}
