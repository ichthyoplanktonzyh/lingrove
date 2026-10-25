import CoreGraphics
import Foundation

/// A lookup freezes one occurrence and its translation language. A writing preview may lend an
/// existing sentence translation; reading leaves it empty so one model interprets both outputs.
/// No AX handles or windows cross this app-owned service boundary.
nonisolated struct LearningLookupInput: Equatable, Hashable, Sendable {
    let target: LearningExplanationInput
    let translationLanguage: LearningLanguage
    var referenceTranslation = ""
}

/// The initial, deliberately short task has no detailed explanation. Both fields belong to the
/// same interpretation; the card publishes them atomically and can save them as a vocabulary usage.
nonisolated struct LearningLookupResult: Codable, Equatable, Hashable, Sendable {
    let meaning: String
    let sentenceTranslation: String
    enum CodingKeys: String, CodingKey { case meaning; case sentenceTranslation = "sentence_translation" }
}

/// Memory-only basic results anchor later details. They are separate from durable explanation
/// records, whose invariant remains a complete meaning plus a nonempty detailed explanation.
nonisolated struct LearningLookupRecord: Equatable, Sendable {
    let input: LearningLookupInput
    let language: LearningLanguage
    let result: LearningLookupResult
    let model: String
    let createdAt: Date
}

/// The same general-model service supports two independently cancellable stages. Keeping this
/// capability separate preserves existing full explanations in sentence and notebook views.
@MainActor
protocol LearningLookupGenerating: LearningExplanationGenerating {
    func lookup(_ input: LearningLookupInput, requestID: String, refresh: Bool) async throws -> LearningLookupRecord
    func explainLookup(_ record: LearningLookupRecord, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord
}

/// Reading supplies a frozen capture directly to the existing dictionary card, without first
/// creating a translated preview. The presenter owns its lightweight session and window geometry.
struct LearningLookupPresentation {
    let id: UUID
    let capture: VocabularyCapture
    let translationLanguage: LearningLanguage
    let anchor: CGRect
}

/// Both writing and reading borrow this presentation capability. The reader supplies receipt
/// validation so a late model reply cannot publish after the host selection has changed.
@MainActor
protocol LearningLookupPresenting: AnyObject {
    func showLookup(_ presentation: LearningLookupPresentation, validate: @escaping () -> Bool, dismiss: @escaping () -> Void)
    func toggleLookupDetails()
}
