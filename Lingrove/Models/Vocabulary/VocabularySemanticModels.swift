import Foundation

/// The archive owns this durable meaning index alongside lexical entries. These value types
/// cross the actor boundary as one immutable snapshot; neither a list nor a graph owns a copy
/// that can be edited independently. Labels are language-specific, identities are not.
nonisolated struct VocabularySemanticIndex: Codable, Equatable, Sendable {
    var nodes: [VocabularyMeaningNode] = []
    var patterns: [VocabularyUsagePattern] = []
    var mappings: [VocabularyMeaningMapping] = []
    var relations: [VocabularyMeaningRelation] = []
    var cues: [VocabularyRetrievalCue] = []
    var cueTargets: [VocabularyCueTarget] = []
}

/// A content concept answers "what is meant"; a communicative function answers "what the
/// speaker is doing". Keeping the distinction prevents a request from becoming a synonym of
/// the event requested. Nodes can exist before any expression has been collected for them.
nonisolated struct VocabularyMeaningNode: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case concept, function }
    let id: UUID
    var kind: Kind = .concept
    var labels: [VocabularyMeaningLabel]
    var definition = ""
    var scopeNote = ""
    var roles: [VocabularyMeaningRole] = []
    var provenance = VocabularySemanticProvenance()
    var createdAt = Date()
    var updatedAt = Date()
    var title: String { labels.first(where: \.preferred)?.text ?? labels.first?.text ?? "" }
}

/// Preferred names and aliases describe one node. Ambiguous search phrases live in cues,
/// whose many-to-many targets deliberately do not assert equivalence with the node.
nonisolated struct VocabularyMeaningLabel: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var language: LearningLanguage?
    var preferred = true
}

nonisolated struct VocabularyMeaningRole: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var description = ""
}

/// A pattern belongs to exactly one sense. Its slots describe syntax, while node roles
/// describe meaning; a mapping may explicitly connect the two without equating their names.
nonisolated struct VocabularyUsagePattern: Codable, Equatable, Identifiable, Sendable {
    enum Formality: String, Codable, CaseIterable, Sendable { case unspecified, informal, neutral, formal }
    enum Medium: String, Codable, CaseIterable, Sendable { case unspecified, spoken, written, both }
    var id = UUID()
    var senseID: UUID
    var template: String
    var slots: [VocabularyPatternSlot] = []
    var formality: Formality = .unspecified
    var medium: Medium = .unspecified
    var region = ""
    var note = ""
    var collocations: [String] = []
    var provenance = VocabularySemanticProvenance()
}

nonisolated struct VocabularyPatternSlot: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var constraint = ""
}

/// This is a claim, not an ownership relationship: several senses may realize one meaning,
/// and one sense may participate in several meanings. A pattern restriction narrows the claim;
/// deleting it must never silently broaden the claim to the entire sense.
nonisolated struct VocabularyMeaningMapping: Codable, Equatable, Identifiable, Sendable {
    enum Relation: String, Codable, CaseIterable, Sendable { case expressesContent, realizesFunction }
    var id = UUID()
    var nodeID: UUID
    var senseID: UUID
    var patternID: UUID?
    var relation: Relation = .expressesContent
    var conditions = ""
    var nuance = ""
    var roleBindings: [VocabularyRoleBinding] = []
    var evidenceIDs: [UUID] = []
    var provenance = VocabularySemanticProvenance()
}

nonisolated struct VocabularyRoleBinding: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var roleID: UUID
    var slotID: UUID
}

/// Relations are explicitly authored. Similar wording, embedding proximity and shared labels
/// never create an edge. `narrower` points from the more specific node to its broader parent.
nonisolated struct VocabularyMeaningRelation: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case narrower, opposite, related }
    var id = UUID()
    var sourceID: UUID
    var targetID: UUID
    var kind: Kind = .related
    var note = ""
    var provenance = VocabularySemanticProvenance()
}

nonisolated struct VocabularyRetrievalCue: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case paraphrase, simpleExpression, personal }
    var id = UUID()
    var text: String
    var language: LearningLanguage?
    var kind: Kind = .paraphrase
}

nonisolated struct VocabularyCueTarget: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var cueID: UUID
    var nodeID: UUID
    var conditions = ""
    var provenance = VocabularySemanticProvenance()
}

/// Evidence and verification are independent: an AI score is not confirmation. Source details
/// stay local with the assertion; captured example IDs preserve the actual occurrence evidence.
nonisolated struct VocabularySemanticProvenance: Codable, Equatable, Sendable {
    enum Origin: String, Codable, CaseIterable, Sendable { case user, imported, model }
    enum Status: String, Codable, CaseIterable, Sendable { case confirmed, proposed }
    var origin: Origin = .user
    var status: Status = .confirmed
    var source = ""
    var confidence: Double?
}
