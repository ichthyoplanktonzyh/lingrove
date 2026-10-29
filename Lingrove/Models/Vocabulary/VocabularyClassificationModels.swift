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
    var frameworkID: UUID?
    var key: String?
    var isRetired = false
    var provenance = VocabularySemanticProvenance(origin: .user, status: .confirmed)
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
    var isHidden = false
    var id: UUID { categoryID }
}
