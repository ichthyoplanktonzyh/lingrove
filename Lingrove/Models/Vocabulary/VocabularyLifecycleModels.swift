import Foundation

/// An interpretation is a claim about one occurrence, not the occurrence itself. The archive
/// retains competing claims and unresolved material; only accepted, sense-linked claims become
/// example cards. External agents manage these values through the same validated CLI transaction.
nonisolated struct VocabularyInterpretation: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case candidate, accepted, rejected }
    var id: UUID
    var occurrenceID: UUID
    var senseID: UUID?
    var status: Status = .candidate
    var meaning = ""
    var meaningLanguage: LearningLanguage?
    var meaningOrigin: VocabularyMeaningOrigin = .captured
    var translation = ""
    var translationLanguage: LearningLanguage?
    var translationVariants: [VocabularyMeaning] = []
    var completeness: VocabularyExample.Completeness = .unknown
    var provenance = VocabularySemanticProvenance()
    var explanations: [LearningExplanationRecord] = []
    var createdAt: Date
}

/// A local user's relationship to one sense owns learning state and selected interpretations.
/// Removing this value never deletes linguistic knowledge or evidence. It has the sense's UUID
/// as its key because a local notebook has exactly one personal collection, not multiple users.
nonisolated struct VocabularyCollectionItem: Codable, Equatable, Identifiable, Sendable {
    var senseID: UUID
    var id: UUID { senseID }
    var interpretationIDs: [UUID] = []
    var isSavedWithoutContext = false
    var note = ""
    var tags: [String] = []
    var content: [VocabularyContentBlock]?
    var review: VocabularyReview?
    var reviewCards: [VocabularyReview]?
    var savedAt: Date
}
