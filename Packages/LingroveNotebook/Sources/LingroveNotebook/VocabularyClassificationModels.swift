import Foundation

/// The archive owns this independent directory above meaning nodes. Membership never changes
/// lexical senses or collections; a portable snapshot carries the directory and local edits together.
public nonisolated struct VocabularyClassificationIndex: Codable, Equatable, Sendable {
    public var frameworks: [VocabularyClassificationFramework] = []
    public var categories: [VocabularyCategory] = []
    public var parents: [VocabularyCategoryParent] = []
    public var memberships: [VocabularyMeaningCategoryMembership] = []
    public var overrides: [VocabularyCategoryOverride] = []

    public init(
        frameworks: [VocabularyClassificationFramework] = [],
        categories: [VocabularyCategory] = [],
        parents: [VocabularyCategoryParent] = [],
        memberships: [VocabularyMeaningCategoryMembership] = [],
        overrides: [VocabularyCategoryOverride] = []
    ) {
        self.frameworks = frameworks
        self.categories = categories
        self.parents = parents
        self.memberships = memberships
        self.overrides = overrides
    }
}

/// A version receipt belongs to the notebook, so opening an older app cannot downgrade its catalog.
public nonisolated struct VocabularyClassificationFramework: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let key: String
    public var version: Int

    public init(
        id: UUID,
        key: String,
        version: Int
    ) {
        self.id = id
        self.key = key
        self.version = version
    }
}

/// Categories describe reusable content or communicative functions. A built-in key is stable
/// across translations and catalog releases; authorship remains independent of catalog ownership.
public nonisolated struct VocabularyCategory: Codable, Equatable, Identifiable, Sendable {
    public enum Axis: String, Codable, CaseIterable, Sendable { case content, function }
    public let id: UUID
    public var axis: Axis
    public var labels: [VocabularyMeaningLabel]
    public var definition = ""
    public var examples: [VocabularyCategoryExample] = []
    public var scopeNote = ""
    public var references: [VocabularyCategoryReference] = []
    public var localizations: [VocabularyCategoryLocalization] = []
    public var frameworkID: UUID?
    public var key: String?
    public var isRetired = false
    public var provenance = VocabularySemanticProvenance(origin: .user, status: .confirmed)

    public init(
        id: UUID,
        axis: Axis,
        labels: [VocabularyMeaningLabel],
        definition: String = "",
        examples: [VocabularyCategoryExample] = [],
        scopeNote: String = "",
        references: [VocabularyCategoryReference] = [],
        localizations: [VocabularyCategoryLocalization] = [],
        frameworkID: UUID? = nil,
        key: String? = nil,
        isRetired: Bool = false,
        provenance: VocabularySemanticProvenance = VocabularySemanticProvenance(origin: .user, status: .confirmed)
    ) {
        self.id = id
        self.axis = axis
        self.labels = labels
        self.definition = definition
        self.examples = examples
        self.scopeNote = scopeNote
        self.references = references
        self.localizations = localizations
        self.frameworkID = frameworkID
        self.key = key
        self.isRetired = isRetired
        self.provenance = provenance
    }
}

/// A classification example illustrates a domain, rather than collecting a lexical sense.
/// It lives with its category and has no notebook membership, review state or evidence identity.
/// Its language tag describes source text without selecting or expanding a learning backend.
public nonisolated struct VocabularyCategoryExample: Codable, Equatable, Sendable {
    public var text: String
    public var language: String?

    public init(
        text: String,
        language: String? = nil
    ) {
        self.text = text
        self.language = language
    }
}

/// Locale-specific presentation belongs to the same stable category. String language tags are
/// independent of study languages (the interface also supports Indonesian and Turkish). Partial
/// custom translations inherit missing fields; examples and source references stay untranslated.
public nonisolated struct VocabularyCategoryLocalization: Codable, Equatable, Sendable {
    public var language: String
    public var name: String?
    public var definition: String?
    public var scopeNote: String?

    public init(
        language: String,
        name: String? = nil,
        definition: String? = nil,
        scopeNote: String? = nil
    ) {
        self.language = language
        self.name = name
        self.definition = definition
        self.scopeNote = scopeNote
    }
}

/// A source mapping explains how an authored category uses an external domain. Combined and
/// narrower mappings deliberately avoid claiming that Lingrove reproduces an external ontology.
/// References travel with portable category data so CLI consumers can inspect the evidence.
public nonisolated struct VocabularyCategoryReference: Codable, Equatable, Sendable {
    public enum Relationship: String, Codable, Sendable { case adapted, combined, narrower }
    public var source: String
    public var identifier: String
    public var url: String
    public var relationship: Relationship
    public var attribution: String?
    public var license: String?

    public init(
        source: String,
        identifier: String,
        url: String,
        relationship: Relationship,
        attribution: String? = nil,
        license: String? = nil
    ) {
        self.source = source
        self.identifier = identifier
        self.url = url
        self.relationship = relationship
        self.attribution = attribution
        self.license = license
    }
}

/// Explicit edges support several parents without duplicating the category or its meanings.
/// Catalog edges are replaced on upgrade; user edges survive and may only connect custom children.
public nonisolated struct VocabularyCategoryParent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let categoryID: UUID
    public let parentID: UUID

    public init(
        id: UUID,
        categoryID: UUID,
        parentID: UUID
    ) {
        self.id = id
        self.categoryID = categoryID
        self.parentID = parentID
    }
}

/// A meaning can belong to several categories. This is directory membership, not a claim that
/// one expression realizes another meaning, and has no personal learning or review state.
public nonisolated struct VocabularyMeaningCategoryMembership: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let nodeID: UUID
    public let categoryID: UUID
    public var provenance = VocabularySemanticProvenance(origin: .user, status: .confirmed)

    public init(
        id: UUID,
        nodeID: UUID,
        categoryID: UUID,
        provenance: VocabularySemanticProvenance = VocabularySemanticProvenance(origin: .user, status: .confirmed)
    ) {
        self.id = id
        self.nodeID = nodeID
        self.categoryID = categoryID
        self.provenance = provenance
    }
}

/// One local overlay per category preserves renamed labels, descriptions and visibility while
/// bundled definitions evolve. Empty optional values mean inherit; an empty definition can clear it.
public nonisolated struct VocabularyCategoryOverride: Codable, Equatable, Identifiable, Sendable {
    public let categoryID: UUID
    public var labels: [VocabularyMeaningLabel]?
    public var definition: String?
    public var examples: [VocabularyCategoryExample]?
    public var scopeNote: String?
    public var references: [VocabularyCategoryReference]?
    public var localizations: [VocabularyCategoryLocalization]?
    public var isHidden = false
    public var id: UUID { categoryID }

    public init(
        categoryID: UUID,
        labels: [VocabularyMeaningLabel]? = nil,
        definition: String? = nil,
        examples: [VocabularyCategoryExample]? = nil,
        scopeNote: String? = nil,
        references: [VocabularyCategoryReference]? = nil,
        localizations: [VocabularyCategoryLocalization]? = nil,
        isHidden: Bool = false
    ) {
        self.categoryID = categoryID
        self.labels = labels
        self.definition = definition
        self.examples = examples
        self.scopeNote = scopeNote
        self.references = references
        self.localizations = localizations
        self.isHidden = isHidden
    }
}

extension VocabularyCategory {
    /// Category payloads predate guidance. Decode absent fields without rewriting old evidence
    /// or requiring a SQL schema migration: guidance belongs in the existing category payload.
    public init(from decoder: Decoder) throws {
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
