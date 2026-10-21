import Combine
import Foundation

/// Acquisition completeness describes what evidence the model actually receives. It is separate
/// from target granularity: a word or a sentence can both be studied with incomplete context.
nonisolated enum LearningExplanationContext: String, Codable, Hashable, Sendable { case sentence, fragment, none }

/// A frozen explanation target contains only the text the user chose and its captured usage.
/// It survives card navigation and can be saved with a vocabulary item without retaining AX
/// elements, an editor, a dictionary provider or a model runtime.
nonisolated struct LearningExplanationInput: Codable, Equatable, Hashable, Sendable {
    let target: String
    let dictionaryForm: String
    let language: LearningLanguage
    let kind: VocabularyEntry.Kind
    let context: String
    let ranges: [VocabularyTextRange]
    let contextKind: LearningExplanationContext
    /// Matching equal text is not enough to identify separately saved translations/usages.
    /// This receipt stays local and is never included in the model prompt.
    let occurrenceIdentity: String?

    init(target: String, dictionaryForm: String, language: LearningLanguage, kind: VocabularyEntry.Kind,
         context: String, ranges: [VocabularyTextRange], contextKind: LearningExplanationContext = .fragment,
         occurrenceIdentity: String? = nil) {
        self.target = target; self.dictionaryForm = dictionaryForm; self.language = language; self.kind = kind
        self.context = context; self.ranges = ranges; self.contextKind = contextKind
        self.occurrenceIdentity = occurrenceIdentity
    }
}

/// The short meaning is independently adoptable; the explanation remains a learning annotation,
/// never an attributed dictionary quotation. Only complete, validated responses become records.
nonisolated struct LearningExplanationResult: Codable, Equatable, Sendable {
    let meaning: String
    let explanation: String
}

/// A durable, context-specific learning artifact. Provider identity is deliberately absent:
/// recording an explanation must not put an endpoint address or credential into an export.
nonisolated struct LearningExplanationRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let input: LearningExplanationInput
    let language: LearningLanguage
    let result: LearningExplanationResult
    let model: String
    let createdAt: Date
}

/// UI sessions borrow this app-owned boundary. Fakes can test cancellation and stale replies
/// without downloading a model or transmitting any captured sentence.
@MainActor
protocol LearningExplanationGenerating: AnyObject {
    var changes: AnyPublisher<Void, Never> { get }
    var language: LearningLanguage { get }
    var isConfigured: Bool { get }
    func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord
    func loadSaved(for input: LearningExplanationInput) async -> LearningExplanationRecord?
    func savedRecord(for input: LearningExplanationInput) -> LearningExplanationRecord?
    func recordDisplay(requestID: String)
}

extension LearningExplanationGenerating {
    func loadSaved(for input: LearningExplanationInput) async -> LearningExplanationRecord? { savedRecord(for: input) }
    func savedRecord(for input: LearningExplanationInput) -> LearningExplanationRecord? { nil }
}
