import LingroveNotebook
import Foundation

/// Meaning identity is independent of language. These read-only rules select an existing name
/// for the notebook's display context; filtering study material never translates or renames it.
/// Editors retain the selected label's UUID so a localized rename cannot overwrite another name.
nonisolated enum VocabularyMeaningLabelPolicy {
    static func preferredLanguages(explanation: LearningLanguage? = nil,
                                   interfaceIdentifiers: [String] = Bundle.main.preferredLocalizations) -> [LearningLanguage] {
        var result = explanation.map { [$0] } ?? []
        for identifier in interfaceIdentifiers {
            if let language = language(for: identifier), !result.contains(language) { result.append(language) }
        }
        return result
    }

    /// Region variants share a display language, but Chinese scripts remain distinct. An
    /// ambiguous/unsupported locale stays unknown rather than relabeling a user's content.
    static func language(for identifier: String) -> LearningLanguage? {
        VocabularyMeaningLabelRules.language(for: identifier)
    }

    static func label(for node: VocabularyMeaningNode, languages: [LearningLanguage]) -> VocabularyMeaningLabel? {
        VocabularyMeaningLabelRules.label(for: node, languages: languages)
    }

    static func label(in labels: [VocabularyMeaningLabel], languages: [LearningLanguage]) -> VocabularyMeaningLabel? {
        VocabularyMeaningLabelRules.label(in: labels, languages: languages)
    }



    static func hasMultipleLanguages(_ entries: [VocabularyEntry]) -> Bool {
        Set(entries.map { $0.language?.rawValue ?? "und" }).count > 1
    }

    static func expressionTitle(_ entry: VocabularyEntry, includeLanguage: Bool) -> String {
        guard includeLanguage else { return entry.expression }
        let language = entry.language?.compactLabel ?? String(localized: "Unspecified", table: "Learning")
        return entry.expression + " · " + language
    }
}

extension VocabularyMeaningNode {
    /// Display-only; the stable `title` property remains available for context-free exports.
    nonisolated func title(in languages: [LearningLanguage]) -> String {
        VocabularyMeaningLabelPolicy.label(for: self, languages: languages)?.text ?? ""
    }
}
