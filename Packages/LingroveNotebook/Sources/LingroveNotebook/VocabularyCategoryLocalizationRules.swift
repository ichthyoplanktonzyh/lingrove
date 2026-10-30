import Foundation

/// Locale-tag validation and authored overlays belong to persisted category data.
/// The host separately chooses an interface locale and renders its presentation.
public nonisolated enum VocabularyCategoryLocalizationRules {
    public static func normalized(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-").lowercased()
    }

    public static func validLanguageTag(_ identifier: String) -> Bool {
        let tag = normalized(identifier)
        return !tag.isEmpty && tag.utf8.count <= 100
            && tag.range(of: "^[a-z]{2,8}(-[a-z0-9]{1,8})*$", options: .regularExpression) != nil
    }

    public static func overlaid(_ category: VocabularyCategory, with overlay: VocabularyCategoryOverride)
        -> [VocabularyCategoryLocalization] {
        var rows = category.localizations
        if overlay.definition != nil {
            for position in rows.indices { rows[position].definition = nil }
        }
        if overlay.scopeNote != nil {
            for position in rows.indices { rows[position].scopeNote = nil }
        }
        if let labels = overlay.labels {
            if labels.contains(where: { $0.language == nil }) {
                for position in rows.indices { rows[position].name = nil }
            }
            var seen = Set<LearningLanguage>()
            for language in labels.compactMap(\.language) where seen.insert(language).inserted {
                if let label = VocabularyMeaningLabelRules.label(in: labels, languages: [language]) {
                    merge(.init(language: language.rawValue, name: label.text), into: &rows)
                }
            }
        }
        for value in overlay.localizations ?? [] { merge(value, into: &rows) }
        return rows
    }

    public static func merge(_ value: VocabularyCategoryLocalization, into rows: inout [VocabularyCategoryLocalization]) {
        guard let position = rows.firstIndex(where: { normalized($0.language) == normalized(value.language) }) else {
            rows.append(value); return
        }
        if let name = value.name { rows[position].name = name }
        if let definition = value.definition { rows[position].definition = definition }
        if let scopeNote = value.scopeNote { rows[position].scopeNote = scopeNote }
    }

    public static func validate(_ values: [VocabularyCategoryLocalization]) throws {
        guard values.count <= 64 else { throw VocabularyError.invalidContent }
        var languages = Set<String>()
        for value in values {
            let tag = normalized(value.language)
            guard validLanguageTag(value.language), languages.insert(tag).inserted,
                  value.name != nil || value.definition != nil || value.scopeNote != nil else { throw VocabularyError.invalidContent }
            if let name = value.name {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 4_096 else {
                    throw VocabularyError.invalidContent
                }
            }
            for text in [value.definition, value.scopeNote].compactMap({ $0 }) where text.utf8.count > 16_384 {
                throw VocabularyError.invalidContent
            }
        }
    }
}
