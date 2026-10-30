import LingroveNotebook
import Combine
import Foundation

/// Acquisition completeness describes what evidence the model actually receives. It is separate
/// from target granularity: a word or a sentence can both be studied with incomplete context.
typealias LearningExplanationContext = LingroveNotebook.LearningExplanationContext

/// A frozen explanation target contains only the text the user chose and its captured usage.
/// It survives card navigation and can be saved with a vocabulary item without retaining AX
/// elements, an editor, a dictionary provider or a model runtime.
typealias LearningExplanationInput = LingroveNotebook.LearningExplanationInput

/// The short meaning is independently adoptable; the explanation remains a learning annotation,
/// never an attributed dictionary quotation. Only complete, validated responses become records.
typealias LearningExplanationResult = LingroveNotebook.LearningExplanationResult

/// A durable, context-specific learning artifact. Provider identity is deliberately absent:
/// recording an explanation must not put an endpoint address or credential into an export.
typealias LearningExplanationRecord = LingroveNotebook.LearningExplanationRecord

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
