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
        let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        guard let base = parts.first else { return nil }
        if base == "zh" {
            if parts.contains("hans") { return .chinese }
            if parts.contains("hant") { return .traditionalChinese }
            if parts.contains(where: { ["cn", "sg", "my"].contains($0) }) { return .chinese }
            if parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) { return .traditionalChinese }
            return nil
        }
        return LearningLanguage(rawValue: String(base))
    }

    static func label(for node: VocabularyMeaningNode, languages: [LearningLanguage]) -> VocabularyMeaningLabel? {
        label(in: node.labels, languages: languages)
    }

    static func label(in labels: [VocabularyMeaningLabel], languages: [LearningLanguage]) -> VocabularyMeaningLabel? {
        for language in languages {
            if let label = preferred(in: labels.filter { $0.language == language }) { return label }
        }
        // Untagged names are retained as authored, without guessing their language. English
        // and then another existing name are last-resort fallbacks, never generated text.
        return preferred(in: labels.filter { $0.language == nil }) ??
            preferred(in: labels.filter { $0.language == .english }) ?? preferred(in: labels)
    }

    private static func preferred(in labels: [VocabularyMeaningLabel]) -> VocabularyMeaningLabel? {
        labels.first(where: \.preferred) ?? labels.first
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
