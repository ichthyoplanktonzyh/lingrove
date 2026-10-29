import Foundation

/// The archive owns this independent directory above meaning nodes. Membership never changes
/// lexical senses or collections; a portable snapshot carries the directory and local edits together.
nonisolated struct VocabularyClassificationIndex: Codable, Equatable, Sendable {
    var frameworks: [VocabularyClassificationFramework] = []
    var categories: [VocabularyCategory] = []
    var parents: [VocabularyCategoryParent] = []
    var memberships: [VocabularyMeaningCategoryMembership] = []
    var overrides: [VocabularyCategoryOverride] = []
}

/// A version receipt belongs to the notebook, so opening an older app cannot downgrade its catalog.
nonisolated struct VocabularyClassificationFramework: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let key: String
    var version: Int
}

/// Categories describe reusable content or communicative functions. A built-in key is stable
/// across translations and catalog releases; authorship remains independent of catalog ownership.
nonisolated struct VocabularyCategory: Codable, Equatable, Identifiable, Sendable {
    enum Axis: String, Codable, CaseIterable, Sendable { case content, function }
    let id: UUID
    var axis: Axis
    var labels: [VocabularyMeaningLabel]
    var definition = ""
    var examples: [VocabularyCategoryExample] = []
    var scopeNote = ""
    var references: [VocabularyCategoryReference] = []
    var localizations: [VocabularyCategoryLocalization] = []
    var frameworkID: UUID?
    var key: String?
    var isRetired = false
    var provenance = VocabularySemanticProvenance(origin: .user, status: .confirmed)
}

/// A classification example illustrates a domain, rather than collecting a lexical sense.
/// It lives with its category and has no notebook membership, review state or evidence identity.
/// Its language tag describes source text without selecting or expanding a learning backend.
nonisolated struct VocabularyCategoryExample: Codable, Equatable, Sendable {
    var text: String
    var language: String?
}

/// Locale-specific presentation belongs to the same stable category. String language tags are
/// independent of study languages (the interface also supports Indonesian and Turkish). Partial
/// custom translations inherit missing fields; examples and source references stay untranslated.
nonisolated struct VocabularyCategoryLocalization: Codable, Equatable, Sendable {
    var language: String
    var name: String?
    var definition: String?
    var scopeNote: String?
}

/// A source mapping explains how an authored category uses an external domain. Combined and
/// narrower mappings deliberately avoid claiming that Lingrove reproduces an external ontology.
/// References travel with portable category data so CLI consumers can inspect the evidence.
nonisolated struct VocabularyCategoryReference: Codable, Equatable, Sendable {
    enum Relationship: String, Codable, Sendable { case adapted, combined, narrower }
    var source: String
    var identifier: String
    var url: String
    var relationship: Relationship
    var attribution: String?
    var license: String?
}

extension VocabularyCategory {
    /// Category payloads predate guidance. Decode absent fields without rewriting old evidence
    /// or requiring a SQL schema migration: guidance belongs in the existing category payload.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        axis = try values.decode(Axis.self, forKey: .axis)
        labels = try values.decode([VocabularyMeaningLabel].self, forKey: .labels)
        definition = try values.decodeIfPresent(String.self, forKey: .definition) ?? ""
        examples = try values.decodeIfPresent([VocabularyCategoryExample].self, forKey: .examples) ?? []
        scopeNote = try values.decodeIfPresent(String.self, forKey: .scopeNote) ?? ""
        references = try values.decodeIfPresent([VocabularyCategoryReference].self, forKey: .references) ?? []
        localizations = try values.decodeIfPresent([VocabularyCategoryLocalization].self, forKey: .localizations) ?? []
        frameworkID = try values.decodeIfPresent(UUID.self, forKey: .frameworkID)
        key = try values.decodeIfPresent(String.self, forKey: .key)
        isRetired = try values.decodeIfPresent(Bool.self, forKey: .isRetired) ?? false
        provenance = try values.decodeIfPresent(VocabularySemanticProvenance.self, forKey: .provenance)
            ?? .init(origin: .user, status: .confirmed)
    }
}

/// Explicit edges support several parents without duplicating the category or its meanings.
/// Catalog edges are replaced on upgrade; user edges survive and may only connect custom children.
nonisolated struct VocabularyCategoryParent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let categoryID: UUID
    let parentID: UUID
}

/// A meaning can belong to several categories. This is directory membership, not a claim that
/// one expression realizes another meaning, and has no personal learning or review state.
nonisolated struct VocabularyMeaningCategoryMembership: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let nodeID: UUID
    let categoryID: UUID
    var provenance = VocabularySemanticProvenance(origin: .user, status: .confirmed)
}

/// One local overlay per category preserves renamed labels, descriptions and visibility while
/// bundled definitions evolve. Empty optional values mean inherit; an empty definition can clear it.
nonisolated struct VocabularyCategoryOverride: Codable, Equatable, Identifiable, Sendable {
    let categoryID: UUID
    var labels: [VocabularyMeaningLabel]?
    var definition: String?
    var examples: [VocabularyCategoryExample]?
    var scopeNote: String?
    var references: [VocabularyCategoryReference]?
    var localizations: [VocabularyCategoryLocalization]?
    var isHidden = false
    var id: UUID { categoryID }
}
