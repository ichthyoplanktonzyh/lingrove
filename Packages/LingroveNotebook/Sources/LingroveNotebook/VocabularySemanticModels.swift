import Foundation

/// The archive owns this durable meaning index alongside lexical entries. These value types
/// cross the actor boundary as one immutable snapshot; neither a list nor a graph owns a copy
/// that can be edited independently. Labels are language-specific, identities are not.
public nonisolated struct VocabularySemanticIndex: Codable, Equatable, Sendable {
    public var nodes: [VocabularyMeaningNode] = []
    public var patterns: [VocabularyUsagePattern] = []
    public var mappings: [VocabularyMeaningMapping] = []
    public var relations: [VocabularyMeaningRelation] = []
    public var cues: [VocabularyRetrievalCue] = []
    public var cueTargets: [VocabularyCueTarget] = []

    public init(
        nodes: [VocabularyMeaningNode] = [],
        patterns: [VocabularyUsagePattern] = [],
        mappings: [VocabularyMeaningMapping] = [],
        relations: [VocabularyMeaningRelation] = [],
        cues: [VocabularyRetrievalCue] = [],
        cueTargets: [VocabularyCueTarget] = []
    ) {
        self.nodes = nodes
        self.patterns = patterns
        self.mappings = mappings
        self.relations = relations
        self.cues = cues
        self.cueTargets = cueTargets
    }
}

/// A content concept answers "what is meant"; a communicative function answers "what the
/// speaker is doing". Keeping the distinction prevents a request from becoming a synonym of
/// the event requested. Nodes can exist before any expression has been collected for them.
public nonisolated struct VocabularyMeaningNode: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case concept, function }
    public let id: UUID
    public var kind: Kind = .concept
    public var labels: [VocabularyMeaningLabel]
    public var definition = ""
    public var scopeNote = ""
    public var roles: [VocabularyMeaningRole] = []
    public var provenance = VocabularySemanticProvenance()
    public var createdAt = Date()
    public var updatedAt = Date()
    public var title: String { labels.first(where: \.preferred)?.text ?? labels.first?.text ?? "" }

    public init(
        id: UUID,
        kind: Kind = .concept,
        labels: [VocabularyMeaningLabel],
        definition: String = "",
        scopeNote: String = "",
        roles: [VocabularyMeaningRole] = [],
        provenance: VocabularySemanticProvenance = VocabularySemanticProvenance(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.labels = labels
        self.definition = definition
        self.scopeNote = scopeNote
        self.roles = roles
        self.provenance = provenance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Preferred names and aliases describe one node. Ambiguous search phrases live in cues,
/// whose many-to-many targets deliberately do not assert equivalence with the node.
public nonisolated struct VocabularyMeaningLabel: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var text: String
    public var language: LearningLanguage?
    public var preferred = true

    public init(
        id: UUID = UUID(),
        text: String,
        language: LearningLanguage? = nil,
        preferred: Bool = true
    ) {
        self.id = id
        self.text = text
        self.language = language
        self.preferred = preferred
    }
}

public nonisolated struct VocabularyMeaningRole: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var description = ""

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = ""
    ) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// A pattern belongs to exactly one sense. Its slots describe syntax, while node roles
/// describe meaning; a mapping may explicitly connect the two without equating their names.
public nonisolated struct VocabularyUsagePattern: Codable, Equatable, Identifiable, Sendable {
    public enum Formality: String, Codable, CaseIterable, Sendable { case unspecified, informal, neutral, formal }
    public enum Medium: String, Codable, CaseIterable, Sendable { case unspecified, spoken, written, both }
    public var id = UUID()
    public var senseID: UUID
    public var template: String
    public var slots: [VocabularyPatternSlot] = []
    public var formality: Formality = .unspecified
    public var medium: Medium = .unspecified
    public var region = ""
    public var note = ""
    public var collocations: [String] = []
    public var provenance = VocabularySemanticProvenance()

    public init(
        id: UUID = UUID(),
        senseID: UUID,
        template: String,
        slots: [VocabularyPatternSlot] = [],
        formality: Formality = .unspecified,
        medium: Medium = .unspecified,
        region: String = "",
        note: String = "",
        collocations: [String] = [],
        provenance: VocabularySemanticProvenance = VocabularySemanticProvenance()
    ) {
        self.id = id
        self.senseID = senseID
        self.template = template
        self.slots = slots
        self.formality = formality
        self.medium = medium
        self.region = region
        self.note = note
        self.collocations = collocations
        self.provenance = provenance
    }
}

public nonisolated struct VocabularyPatternSlot: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var constraint = ""

    public init(
        id: UUID = UUID(),
        name: String,
        constraint: String = ""
    ) {
        self.id = id
        self.name = name
        self.constraint = constraint
    }
}

/// This is a claim, not an ownership relationship: several senses may realize one meaning,
/// and one sense may participate in several meanings. A pattern restriction narrows the claim;
/// deleting it must never silently broaden the claim to the entire sense.
public nonisolated struct VocabularyMeaningMapping: Codable, Equatable, Identifiable, Sendable {
    public enum Relation: String, Codable, CaseIterable, Sendable { case expressesContent, realizesFunction }
    public var id = UUID()
    public var nodeID: UUID
    public var senseID: UUID
    public var patternID: UUID?
    public var relation: Relation = .expressesContent
    public var conditions = ""
    public var nuance = ""
    public var roleBindings: [VocabularyRoleBinding] = []
    public var evidenceIDs: [UUID] = []
    public var provenance = VocabularySemanticProvenance()

    public init(
        id: UUID = UUID(),
        nodeID: UUID,
        senseID: UUID,
        patternID: UUID? = nil,
        relation: Relation = .expressesContent,
        conditions: String = "",
        nuance: String = "",
        roleBindings: [VocabularyRoleBinding] = [],
        evidenceIDs: [UUID] = [],
        provenance: VocabularySemanticProvenance = VocabularySemanticProvenance()
    ) {
        self.id = id
        self.nodeID = nodeID
        self.senseID = senseID
        self.patternID = patternID
        self.relation = relation
        self.conditions = conditions
        self.nuance = nuance
        self.roleBindings = roleBindings
        self.evidenceIDs = evidenceIDs
        self.provenance = provenance
    }
}

public nonisolated struct VocabularyRoleBinding: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var roleID: UUID
    public var slotID: UUID

    public init(
        id: UUID = UUID(),
        roleID: UUID,
        slotID: UUID
    ) {
        self.id = id
        self.roleID = roleID
        self.slotID = slotID
    }
}

/// Relations are explicitly authored. Similar wording, embedding proximity and shared labels
/// never create an edge. `narrower` points from the more specific node to its broader parent.
public nonisolated struct VocabularyMeaningRelation: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case narrower, opposite, related }
    public var id = UUID()
    public var sourceID: UUID
    public var targetID: UUID
    public var kind: Kind = .related
    public var note = ""
    public var provenance = VocabularySemanticProvenance()

    public init(
        id: UUID = UUID(),
        sourceID: UUID,
        targetID: UUID,
        kind: Kind = .related,
        note: String = "",
        provenance: VocabularySemanticProvenance = VocabularySemanticProvenance()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.note = note
        self.provenance = provenance
    }
}

public nonisolated struct VocabularyRetrievalCue: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case paraphrase, simpleExpression, personal }
    public var id = UUID()
    public var text: String
    public var language: LearningLanguage?
    public var kind: Kind = .paraphrase

    public init(
        id: UUID = UUID(),
        text: String,
        language: LearningLanguage? = nil,
        kind: Kind = .paraphrase
    ) {
        self.id = id
        self.text = text
        self.language = language
        self.kind = kind
    }
}

public nonisolated struct VocabularyCueTarget: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var cueID: UUID
    public var nodeID: UUID
    public var conditions = ""
    public var provenance = VocabularySemanticProvenance()

    public init(
        id: UUID = UUID(),
        cueID: UUID,
        nodeID: UUID,
        conditions: String = "",
        provenance: VocabularySemanticProvenance = VocabularySemanticProvenance()
    ) {
        self.id = id
        self.cueID = cueID
        self.nodeID = nodeID
        self.conditions = conditions
        self.provenance = provenance
    }
}

/// Authorship and adoption are independent: confirmed means usable in the notebook, not
/// necessarily reviewed by a human. Authorized agent writes retain model origin and are adopted
/// by default; explicit uncertainty and invalidated evidence can still produce proposed claims.
public nonisolated struct VocabularySemanticProvenance: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, CaseIterable, Sendable { case user, imported, model }
    public enum Status: String, Codable, CaseIterable, Sendable { case confirmed, proposed }
    public var origin: Origin = .user
    public var status: Status = .confirmed
    public var source = ""
    public var confidence: Double?

    public init(
        origin: Origin = .user,
        status: Status = .confirmed,
        source: String = "",
        confidence: Double? = nil
    ) {
        self.origin = origin
        self.status = status
        self.source = source
        self.confidence = confidence
    }
}
