import Foundation

/// Select existing authored labels without translating, renaming or creating knowledge.
public nonisolated enum VocabularyMeaningLabelRules {
    public static func language(for identifier: String) -> LearningLanguage? {
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

    public static func label(for node: VocabularyMeaningNode, languages: [LearningLanguage]) -> VocabularyMeaningLabel? {
        label(in: node.labels, languages: languages)
    }

    public static func label(in labels: [VocabularyMeaningLabel], languages: [LearningLanguage]) -> VocabularyMeaningLabel? {
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
}
