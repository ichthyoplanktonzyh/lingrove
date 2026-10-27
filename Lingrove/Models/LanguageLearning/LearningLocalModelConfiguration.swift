import Foundation

/// The controller freezes a model destination, adapter and native capacity before leaving
/// MainActor. Planning and generation consume this same short-lived value; neither reaches back
/// into mutable UI preferences while a native operation is queued. It owns no model allocation.
nonisolated struct LearningLocalModelConfiguration: Equatable, Sendable {
    let modelURL: URL
    let template: LearningChatTemplate
    let contextWindowTokens: Int
    var samplingOverrides = ModelSamplingOverrides()
    /// Request-only output syntax. It never becomes part of the loaded-model identity, and
    /// nil preserves ordinary text sampling for translation and expression assistance.
    var outputGrammar: String?
}
