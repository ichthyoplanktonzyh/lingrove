import Foundation

/// Stable local persistence families, independent of a physical database or workspace scope.
/// Each host maps these trusted names to its own tables and adds its own ownership columns.
/// Changing a family or index definition is a persisted-format change, not a UI rename.
public nonisolated enum VocabularyPersistenceEntity: String, Codable, CaseIterable, Sendable {
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

    public var parent: Self? {
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
    public var indexKeys: [VocabularyPersistenceIndex] {
        switch self {
        case .classificationFrameworks: [.catalogKey]
        case .categories: [.frameworkID, .catalogKey, .axis]
        case .categoryParents: [.categoryID, .parentCategoryID]
        case .categoryMemberships: [.meaningID, .categoryID]
        case .entries: [.lookupKey, .language, .expression]
        case .senses: [.meaning]
        case .usages: [.occurrenceID, .senseID, .status]
        case .collections: [.senseID]
        case .collectionInterpretations: [.usageID]
        case .meaningNodes: [.kind]
        case .meaningLabels: [.language, .text, .preferred]
        case .meaningRoles, .patternSlots: [.name]
        case .usagePatterns: [.template]
        case .meaningMappings: [.meaningID, .patternID, .relation]
        case .mappingRoles: [.roleID, .slotID]
        case .mappingEvidence: [.usageID]
        case .meaningRelations: [.targetID, .relation]
        case .retrievalCues: [.language, .text]
        case .cueTargets: [.meaningID]
        default: []
        }
    }
}

/// Typed searchable/relational leaf values accompany an opaque entity payload. An absent value
/// is SQL NULL; an absent key is malformed input. These are not a remote synchronization schema.
public nonisolated enum VocabularyPersistenceIndex: String, Codable, CaseIterable, Sendable {
    case catalogKey = "catalog_key"
    case frameworkID = "framework_id"
    case axis = "axis"
    case categoryID = "category_id"
    case parentCategoryID = "parent_category_id"
    case meaningID = "meaning_id"
    case lookupKey = "lookup_key"
    case language = "language"
    case expression = "expression"
    case meaning = "meaning"
    case occurrenceID = "occurrence_id"
    case senseID = "sense_id"
    case status = "status"
    case usageID = "usage_id"
    case kind = "kind"
    case text = "text"
    case preferred = "preferred"
    case name = "name"
    case template = "template"
    case patternID = "pattern_id"
    case relation = "relation"
    case roleID = "role_id"
    case slotID = "slot_id"
    case targetID = "target_id"
}
