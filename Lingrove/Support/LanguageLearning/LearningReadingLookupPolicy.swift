import Foundation

/// Routes frozen reading evidence before any model work. Sentence coverage comes from the
/// captured occurrence, not punctuation alone; a punctuation-free full selection remains valid.
nonisolated enum LearningReadingLookupPolicy {
    static func capture(_ selection: LearningReadingSelection, language: LearningLanguage?) -> VocabularyCapture? {
        if selection.source == .screenshot { return nil }
        let text = selection.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = LearningUnitPolicy.words(in: text, language: language)
        let oneWord = words.count <= 1
        if selection.source != .pointer {
            if let context = selection.context, context.isComplete || context.hasBlockCoverage, context.selectionCoversContext,
               !oneWord || trimmed.last.map({ ".!?。！？".contains($0) }) == true {
                return nil
            }
            // An incomplete captured example is stronger evidence than terminal punctuation.
            // Without surrounding evidence, punctuation/screen regions are positive hints only.
            if selection.context == nil, translationHint(trimmed, words: words.count, source: selection.source) { return nil }
        }
        return VocabularyCapture(expression: trimmed, dictionaryForm: trimmed, language: language,
            kind: oneWord ? .word : .expression, example: selection.vocabularyContext)
    }

    private static func translationHint(_ text: String, words: Int, source: LearningReadingSource) -> Bool {
        if source == .screenshot { return true }
        guard let last = text.last else { return false }
        if ".!?。！？".contains(last) { return true }
        // A colon can introduce a complete statement's list, while a one-word label such as
        // "bank:" remains a dictionary target when no wider selection evidence is available.
        return words > 1 && ":：".contains(last)
    }
}
