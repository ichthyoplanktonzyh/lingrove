import Foundation

/// Routes frozen reading evidence before any model work. Sentence coverage comes from the
/// captured occurrence, not punctuation alone; a punctuation-free full selection remains valid.
nonisolated enum LearningReadingLookupPolicy {
    static func capture(_ selection: LearningReadingSelection, language: LearningLanguage) -> VocabularyCapture? {
        let text = selection.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = LearningUnitPolicy.words(in: text, language: language)
        let oneWord = words.count <= 1
        if selection.source != .pointer {
            if let example = selection.vocabularyContext, example.completeness == .sentence,
               example.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                return nil
            }
            // An incomplete captured example is stronger evidence than terminal punctuation.
            // Without surrounding evidence, punctuation/screen regions are positive hints only.
            if selection.vocabularyContext == nil,
               selection.source == .screenshot || trimmed.last.map({ ".!?。！？".contains($0) }) == true { return nil }
        }
        return VocabularyCapture(expression: text, dictionaryForm: text, language: language,
            kind: oneWord ? .word : .expression, example: selection.vocabularyContext)
    }
}
