import Foundation

/// Reference mode changes what the model may read, never which editor range is writable.
nonisolated enum LearningReferenceMode: String, CaseIterable, Codable, Sendable {
    case currentSentence, draft
}

/// One request's immutable text-only payload. The coordinator retains the separate AX capture;
/// services receive no editor handles and cannot infer a replacement range from model output.
nonisolated struct LearningTranslationInput: Equatable, Hashable, Sendable {
    let source: String
    var referenceBefore: String = ""
    var referenceAfter: String = ""
    var style = LearningTranslationStyle()
    var origin: LearningTranslationOrigin = .writing
    /// Reading eligibility follows the captured source through planning and generation. Writing
    /// ignores this field; legacy selected-text callers retain their explicit selection default.
    var readingSource: LearningReadingSource = .selection

    static func captured(value: String, range: NSRange, source: String, mode: LearningReferenceMode) -> Self {
        guard mode == .draft, NSMaxRange(range) <= value.utf16.count else { return .init(source: source) }
        let text = value as NSString
        // Bound local extraction before tokenization. Preserve the text nearest the target; the
        // exact model-aware planner may shrink these excerpts further, but never touches source.
        let before = text.substring(to: range.location)
        let after = text.substring(from: NSMaxRange(range))
        return .init(source: source, referenceBefore: String(before.suffix(65_536)), referenceAfter: String(after.prefix(65_536)))
    }
}

/// Origin chooses eligibility and direction, never a separate prompt template or runtime.
nonisolated enum LearningTranslationOrigin: Hashable, Sendable { case writing, reading }
