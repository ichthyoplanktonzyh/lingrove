import Foundation

/// Routes frozen reading evidence before any model work. Sentence coverage comes from the
/// captured occurrence, not punctuation alone; a punctuation-free full selection remains valid.
nonisolated enum LearningReadingLookupPolicy {
    /// A route explains its acquisition evidence without adding copy to the existing cards.
    /// The coordinator logs this value and passes its capture to the existing lookup session.
    enum Reason: String {
        case screenRegion, wholeSentence, wholeBlock, wholeUnverifiedSentence, terminalText
        case pointerTarget, contextualUnit, standaloneUnit
    }
    struct Decision {
        let capture: VocabularyCapture?
        let reason: Reason
    }

    static func capture(_ selection: LearningReadingSelection, language: LearningLanguage?) -> VocabularyCapture? {
        decision(selection, language: language).capture
    }

    static func decision(_ selection: LearningReadingSelection, language: LearningLanguage?) -> Decision {
        if selection.source == .screenshot { return .init(capture: nil, reason: .screenRegion) }
        let text = selection.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = LearningUnitPolicy.words(in: text, language: language)
        let oneWord = words.count <= 1
        if selection.source != .pointer {
            if let context = selection.context, context.selectionCoversContext {
                if context.isComplete, !oneWord || translationHint(context.text, words: words.count, source: selection.source) {
                    return .init(capture: nil, reason: .wholeSentence)
                }
                // Explicitly selecting the entire available material expresses translation
                // intent even when the host cannot certify its outer boundaries. Known crops
                // and a word/phrase inside a larger sentence still belong to contextual lookup.
                if context.completeness == .unknown, !oneWord {
                    if context.hasBlockCoverage { return .init(capture: nil, reason: .wholeBlock) }
                    if translationHint(context.text, words: words.count, source: selection.source) {
                        return .init(capture: nil, reason: .wholeUnverifiedSentence)
                    }
                }
            }
            // An incomplete captured example is stronger evidence than terminal punctuation.
            // Without surrounding evidence, punctuation/screen regions are positive hints only.
            if selection.context == nil, translationHint(trimmed, words: words.count, source: selection.source) {
                return .init(capture: nil, reason: .terminalText)
            }
        }
        let capture = VocabularyCapture(expression: trimmed, dictionaryForm: trimmed, language: language,
            kind: oneWord ? .word : .expression, example: selection.vocabularyContext)
        return .init(capture: capture, reason: selection.source == .pointer ? .pointerTarget :
            selection.context == nil ? .standaloneUnit : .contextualUnit)
    }

    private static func translationHint(_ text: String, words: Int, source: LearningReadingSource) -> Bool {
        if source == .screenshot { return true }
        if LearningReadingContextPolicy.hasTerminator(text) { return true }
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        // A colon can introduce a complete statement's list, while a one-word label such as
        // "bank:" remains a dictionary target when no wider selection evidence is available.
        return words > 1 && ":：".contains(last)
    }
}
