import Foundation

/// Acquisition completeness describes what evidence the model actually receives. It is separate
/// from target granularity: a word or a sentence can both be studied with incomplete context.
public nonisolated enum LearningExplanationContext: String, Codable, Hashable, Sendable { case sentence, fragment, unknown, none }

/// A frozen explanation target contains only the text the user chose and its captured usage.
/// It survives card navigation and can be saved with a vocabulary item without retaining AX
/// elements, an editor, a dictionary provider or a model runtime.
public nonisolated struct LearningExplanationInput: Codable, Equatable, Hashable, Sendable {
    public let target: String
    public let dictionaryForm: String
    /// A hint about the study material, never a prerequisite or the response language.
    public let language: LearningLanguage?
    public let kind: VocabularyEntry.Kind
    public let context: String
    public let ranges: [VocabularyTextRange]
    public let contextKind: LearningExplanationContext
    /// Matching equal text is not enough to identify separately saved translations/usages.
    /// This receipt stays local and is never included in the model prompt.
    public let occurrenceIdentity: String?

    public init(target: String, dictionaryForm: String, language: LearningLanguage?, kind: VocabularyEntry.Kind,
         context: String, ranges: [VocabularyTextRange], contextKind: LearningExplanationContext = .fragment,
         occurrenceIdentity: String? = nil) {
        self.target = target; self.dictionaryForm = dictionaryForm; self.language = language; self.kind = kind
        self.context = context; self.ranges = ranges; self.contextKind = contextKind
        self.occurrenceIdentity = occurrenceIdentity
    }
}

/// The short meaning is independently adoptable; the explanation remains a learning annotation,
/// never an attributed dictionary quotation. Only complete, validated responses become records.
public nonisolated struct LearningExplanationResult: Codable, Equatable, Sendable {
    public let meaning: String
    public let explanation: String

    public init(
        meaning: String,
        explanation: String
    ) {
        self.meaning = meaning
        self.explanation = explanation
    }
}

/// A durable, context-specific learning artifact. Provider identity is deliberately absent:
/// recording an explanation must not put an endpoint address or credential into an export.
public nonisolated struct LearningExplanationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let input: LearningExplanationInput
    public let language: LearningLanguage
    public let result: LearningExplanationResult
    public let model: String
    public let createdAt: Date

    public init(
        id: UUID,
        input: LearningExplanationInput,
        language: LearningLanguage,
        result: LearningExplanationResult,
        model: String,
        createdAt: Date
    ) {
        self.id = id
        self.input = input
        self.language = language
        self.result = result
        self.model = model
        self.createdAt = createdAt
    }
}
