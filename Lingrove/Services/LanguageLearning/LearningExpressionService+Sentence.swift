import Foundation

/// Writing and reading share translation generation while retaining their own captured scope.
/// Translation completion ends the model request; lexical recognition is owned by coordinators.
extension LearningExpressionService: LearningSentenceGenerating {
    func translateReadingSelection(source: String, sourceLanguage: LearningLanguage, targetLanguage: LearningLanguage,
                                   readingSource: LearningReadingSource,
                                   onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        try await translator.generate(input: .init(source: source, origin: .reading, readingSource: readingSource),
            task: .translation(source: sourceLanguage, target: targetLanguage), onPartial: onPartial)
    }
    func translateReadingSelection(source: String, sourceLanguage: LearningLanguage, targetLanguage: LearningLanguage,
                                   readingSource: LearningReadingSource = .selection) async throws -> String {
        try await translator.generate(input: .init(source: source, origin: .reading, readingSource: readingSource),
                                      task: .translation(source: sourceLanguage, target: targetLanguage))
    }

    func translateSentence(
        input: LearningTranslationInput, sourceLanguage: LearningLanguage,
        targetLanguage: LearningLanguage
    ) async throws -> String {
        try await translator.generate(input: input, task: .translation(source: sourceLanguage, target: targetLanguage))
    }
    func translateSentence(input: LearningTranslationInput, sourceLanguage: LearningLanguage, targetLanguage: LearningLanguage,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        try await translator.generate(input: input, task: .translation(source: sourceLanguage, target: targetLanguage),
                                      onPartial: onPartial)
    }
    func translateSentence(source: String, sourceLanguage: LearningLanguage,
                           targetLanguage: LearningLanguage) async throws -> String {
        try await translator.generate(source: source, task: .translation(source: sourceLanguage, target: targetLanguage))
    }

}
