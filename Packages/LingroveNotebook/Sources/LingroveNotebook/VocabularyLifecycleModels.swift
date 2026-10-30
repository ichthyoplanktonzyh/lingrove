import Foundation

/// An interpretation is a claim about one occurrence, not the occurrence itself. The archive
/// retains competing claims and unresolved material; only accepted, sense-linked claims become
/// example cards. External agents manage these values through the same validated CLI transaction.
public nonisolated struct VocabularyInterpretation: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case candidate, accepted, rejected }
    public var id: UUID
    public var occurrenceID: UUID
    public var senseID: UUID?
    public var status: Status = .candidate
    public var meaning = ""
    public var meaningLanguage: LearningLanguage?
    public var meaningOrigin: VocabularyMeaningOrigin = .captured
    public var translation = ""
    public var translationLanguage: LearningLanguage?
    public var translationVariants: [VocabularyMeaning] = []
    public var completeness: VocabularyExample.Completeness = .unknown
    public var provenance = VocabularySemanticProvenance()
    public var explanations: [LearningExplanationRecord] = []
    public var createdAt: Date

    public init(
        id: UUID,
        occurrenceID: UUID,
        senseID: UUID? = nil,
        status: Status = .candidate,
        meaning: String = "",
        meaningLanguage: LearningLanguage? = nil,
        meaningOrigin: VocabularyMeaningOrigin = .captured,
        translation: String = "",
        translationLanguage: LearningLanguage? = nil,
        translationVariants: [VocabularyMeaning] = [],
        completeness: VocabularyExample.Completeness = .unknown,
        provenance: VocabularySemanticProvenance = VocabularySemanticProvenance(),
        explanations: [LearningExplanationRecord] = [],
        createdAt: Date
    ) {
        self.id = id
        self.occurrenceID = occurrenceID
        self.senseID = senseID
        self.status = status
        self.meaning = meaning
        self.meaningLanguage = meaningLanguage
        self.meaningOrigin = meaningOrigin
        self.translation = translation
        self.translationLanguage = translationLanguage
        self.translationVariants = translationVariants
        self.completeness = completeness
        self.provenance = provenance
        self.explanations = explanations
        self.createdAt = createdAt
    }
}

/// A local user's relationship to one sense owns learning state and selected interpretations.
/// Removing this value never deletes linguistic knowledge or evidence. It has the sense's UUID
/// as its key because a local notebook has exactly one personal collection, not multiple users.
public nonisolated struct VocabularyCollectionItem: Codable, Equatable, Identifiable, Sendable {
    public var senseID: UUID
    public var id: UUID { senseID }
    public var interpretationIDs: [UUID] = []
    public var isSavedWithoutContext = false
    public var note = ""
    public var tags: [String] = []
    public var content: [VocabularyContentBlock]?
    public var review: VocabularyReview?
    public var reviewCards: [VocabularyReview]?
    public var savedAt: Date

    public init(
        senseID: UUID,
        interpretationIDs: [UUID] = [],
        isSavedWithoutContext: Bool = false,
        note: String = "",
        tags: [String] = [],
        content: [VocabularyContentBlock]? = nil,
        review: VocabularyReview? = nil,
        reviewCards: [VocabularyReview]? = nil,
        savedAt: Date
    ) {
        self.senseID = senseID
        self.interpretationIDs = interpretationIDs
        self.isSavedWithoutContext = isSavedWithoutContext
        self.note = note
        self.tags = tags
        self.content = content
        self.review = review
        self.reviewCards = reviewCards
        self.savedAt = savedAt
    }
}
