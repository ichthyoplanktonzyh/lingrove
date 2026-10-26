import CoreGraphics
import Foundation

/// Separate from continuation generation: learning has its own model, prompt and output contract.
/// The app environment owns the implementation; tests can supply a controllable event stream.
@MainActor
protocol LearningSentenceGenerating: LearningDisplayReporting {
    var settings: SuggestionSettingsModel { get }
    func translateReadingSelection(source: String, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage,
                                   readingSource: LearningReadingSource) async throws -> String
    func translateReadingSelection(source: String, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage,
                                   readingSource: LearningReadingSource,
                                   onPartial: @escaping @MainActor (String) -> Void) async throws -> String
    func translateSentence(source: String, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage) async throws -> String
    func translateSentence(input: LearningTranslationInput, sourceLanguage: LearningLanguage?,
                           targetLanguage: LearningLanguage) async throws
        -> String
    /// Prefixes are display-only snapshots. Only the returned, validated value may be cached,
    /// spoken or used to replace the saved source range.
    func translateSentence(input: LearningTranslationInput, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String
}

extension LearningSentenceGenerating {
    func translateReadingSelection(source: String, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage,
                                   readingSource: LearningReadingSource,
                                   onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        try await translateReadingSelection(source: source, sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage, readingSource: readingSource)
    }
    func translateSentence(input: LearningTranslationInput, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        try await translateSentence(input: input, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }
    func translateReadingSelection(source: String, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage,
                                   readingSource: LearningReadingSource = .selection) async throws -> String {
        try await translateSentence(source: source, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }
    func translateSentence(input: LearningTranslationInput, sourceLanguage: LearningLanguage?,
                           targetLanguage: LearningLanguage) async throws
        -> String {
        try await translateSentence(source: input.source, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }
}

/// Memory-only learning display. The original AX capture stays in the coordinator; the view
/// receives only versioned text and an explicit confirmation callback. Ordinary typing stays in
/// the host editor, independently of whether the writer chooses to replace this preview.
struct LearningSentencePresentation {
    let id: UUID
    let source: String
    let translation: String
    let sourceLanguage: LearningLanguage?
    let targetLanguage: LearningLanguage
    let caret: CGRect
    let isExpanded: Bool
    let isGenerating: Bool
    let message: String
    let previousTranslation: String?
    let shortcutLabel: String
    var isStale: Bool = false
    var units: [LearningUnit] = []
    var unitStage: LearningUnitStage = .pending
    var targetIsSelection = false
    var canReplace = false
    /// Shown independently of generation messages so a read-only capture stays
    /// understandable after those messages are cleared or replaced.
    var replacementUnavailableReason: String?
    var replacementShortcutLabel = ""
    var isCommitting = false
    var isError = false
    var readingSource: LearningReadingSource?
    /// A nonempty streamed prefix is still incomplete and cannot be spoken or written back.
    var isTranslating = false
    /// Frozen acquisition evidence shared by vocabulary saves and explicit contextual explanation.
    var vocabularyContext: VocabularyExample?
    var vocabularyAppBundleIdentifier: String?

    var targetLabel: String {
        switch readingSource {
        case .pointer: String(localized: "Target: Pointed word", table: "Learning")
        case .screenshot: String(localized: "Target: Screen region", table: "Learning")
        default:
            if targetIsSelection {
                String(localized: "Target: Selection", table: "Learning")
            } else {
                String(localized: "Target: Current sentence", table: "Learning")
            }
        }
    }
}

@MainActor
protocol LearningSentencePresenting: AnyObject {
    var isVisible: Bool { get }
    func hide()
    func dismissDetail() -> Bool
    func containsGlobalInteraction(at point: CGPoint) -> Bool
    func show(_ presentation: LearningSentencePresentation, expand: @escaping () -> Void, dismiss: @escaping () -> Void)
    func show(
        _ presentation: LearningSentencePresentation, expand: @escaping () -> Void, dismiss: @escaping () -> Void,
        replace: (() -> Void)?)
}

extension LearningSentencePresenting {
    func show(
        _ presentation: LearningSentencePresentation, expand: @escaping () -> Void, dismiss: @escaping () -> Void,
        replace: (() -> Void)?
    ) { show(presentation, expand: expand, dismiss: dismiss) }
    func dismissDetail() -> Bool { false }
    func containsGlobalInteraction(at point: CGPoint) -> Bool { false }
}
