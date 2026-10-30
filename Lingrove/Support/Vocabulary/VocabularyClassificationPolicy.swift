import LingroveNotebook
import Foundation

/// The app reuses the shared data rules; platform presentation stays in host extensions.
typealias VocabularyClassificationPolicy = LingroveNotebook.VocabularyClassificationPolicy

extension VocabularyClassificationPolicy {
    nonisolated static func title(_ category: VocabularyCategory, in index: VocabularyClassificationIndex,
                      interfaceIdentifiers: [String] = Bundle.main.preferredLocalizations) -> String {
        presentation(category, in: index, interfaceIdentifiers: interfaceIdentifiers).name
    }

    nonisolated static func presentation(_ category: VocabularyCategory, in index: VocabularyClassificationIndex,
                             interfaceIdentifiers: [String] = Bundle.main.preferredLocalizations)
        -> VocabularyCategoryLocalizationPolicy.Presentation {
        VocabularyCategoryLocalizationPolicy.presentation(effective(category, in: index), identifiers: interfaceIdentifiers)
    }
}
