import Foundation

/// Pure category presentation rules keep interface language separate from the language being
/// learned. Views and pickers consume one resolved value; CLI, SQLite and exports retain every
/// authored translation. Nothing here translates source examples or creates vocabulary records.
nonisolated enum VocabularyCategoryLocalizationPolicy {
    struct Presentation: Equatable {
        var name: String
        var definition: String
        var scopeNote: String
    }

    static func normalized(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-").lowercased()
    }

    static func validLanguageTag(_ identifier: String) -> Bool {
        let tag = normalized(identifier)
        return !tag.isEmpty && tag.utf8.count <= 100
            && tag.range(of: "^[a-z]{2,8}(-[a-z0-9]{1,8})*$", options: .regularExpression) != nil
    }

    /// Region aliases fall back within their language, preserving the Chinese script distinction.
    /// An unknown locale can still be authored by a user; it is never coerced into a study language.
    static func candidates(_ identifiers: [String]) -> [String] {
        var result: [String] = []
        for identifier in identifiers.prefix(1) {
            let tag = normalized(identifier)
            guard !tag.isEmpty else { continue }
            result.append(tag)
            let pieces = tag.split(separator: "-").map(String.init)
            if pieces.first == "zh" {
                if case .language(let language) = InterfaceLanguageNormalizer.selection(forStoredIdentifier: tag) {
                    result.append(normalized(language.rawValue))
                }
            } else if let base = pieces.first {
                result.append(base)
            }
        }
        result.append("en")
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    static func editingLanguage(_ identifiers: [String]) -> String {
        let first = identifiers.first ?? "en"
        if case .language(let language) = InterfaceLanguageNormalizer.selection(forStoredIdentifier: first) {
            return language.rawValue
        }
        let parts = normalized(first).split(separator: "-")
        if let base = parts.first, let supported = InterfaceLanguage(rawValue: String(base)) { return supported.rawValue }
        return first.isEmpty ? "en" : first.replacingOccurrences(of: "_", with: "-")
    }

    static func presentation(_ category: VocabularyCategory, identifiers: [String]) -> Presentation {
        let preferences = candidates(identifiers)
        let rows = Dictionary(category.localizations.map { (normalized($0.language), $0) }, uniquingKeysWith: { first, _ in first })
        let languages = preferences.compactMap(VocabularyMeaningLabelPolicy.language(for:))
        let originalName = VocabularyMeaningLabelPolicy.label(in: category.labels, languages: languages)?.text ?? ""
        func resolve(_ field: KeyPath<VocabularyCategoryLocalization, String?>, original: String) -> String {
            for language in preferences {
                if let value = rows[language]?[keyPath: field] { return value }
            }
            return original
        }
        return .init(name: resolve(\.name, original: originalName),
            definition: resolve(\.definition, original: category.definition), scopeNote: resolve(\.scopeNote, original: category.scopeNote))
    }

    /// Old untagged overrides remain authoritative authored text. Clear conflicting translated
    /// fields before applying the newer per-language overrides so earlier user edits stay visible.
    static func overlaid(_ category: VocabularyCategory, with overlay: VocabularyCategoryOverride)
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
                if let label = VocabularyMeaningLabelPolicy.label(in: labels, languages: [language]) {
                    merge(.init(language: language.rawValue, name: label.text), into: &rows)
                }
            }
        }
        for value in overlay.localizations ?? [] { merge(value, into: &rows) }
        return rows
    }

    static func merge(_ value: VocabularyCategoryLocalization, into rows: inout [VocabularyCategoryLocalization]) {
        guard let position = rows.firstIndex(where: { normalized($0.language) == normalized(value.language) }) else {
            rows.append(value); return
        }
        if let name = value.name { rows[position].name = name }
        if let definition = value.definition { rows[position].definition = definition }
        if let scopeNote = value.scopeNote { rows[position].scopeNote = scopeNote }
    }

    static func matches(_ category: VocabularyCategory, term: String) -> Bool {
        category.labels.contains { $0.text.localizedStandardContains(term) }
            || category.definition.localizedStandardContains(term)
            || category.localizations.contains {
                ($0.name?.localizedStandardContains(term) ?? false) || ($0.definition?.localizedStandardContains(term) ?? false)
            }
    }

    /// One editor writes only changed fields in its captured UI locale. Saving a fallback value
    /// unchanged must not manufacture a translation or overwrite another language's authored text.
    static func edited(_ category: VocabularyCategory, in index: VocabularyClassificationIndex,
                       language: String, name: String, definition: String, hidden: Bool = false,
                       restoringDefaults: Bool = false) -> (category: VocabularyCategory, overlay: VocabularyCategoryOverride?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !index.categories.contains(where: { $0.id == category.id }) {
            var value = category
            value.labels[0].text = name
            value.labels[0].language = VocabularyMeaningLabelPolicy.language(for: language)
            value.definition = definition
            value.localizations = [.init(language: language, name: name, definition: definition)]
            return (value, hidden ? .init(categoryID: value.id, isHidden: true) : nil)
        }
        var overlay = restoringDefaults ? VocabularyCategoryOverride(categoryID: category.id) :
            index.overrides.first { $0.categoryID == category.id } ?? .init(categoryID: category.id)
        let base = restoringDefaults ? category : VocabularyClassificationPolicy.effective(category, in: index)
        let before = presentation(base, identifiers: [language])
        var changed = VocabularyCategoryLocalization(language: language)
        if name != before.name { changed.name = name }
        if definition != before.definition { changed.definition = definition }
        if changed.name != nil || changed.definition != nil {
            var rows = overlay.localizations ?? []
            merge(changed, into: &rows)
            overlay.localizations = rows
        }
        overlay.isHidden = hidden
        let hasContent = overlay.isHidden || overlay.labels != nil || overlay.definition != nil || overlay.examples != nil
            || overlay.scopeNote != nil || overlay.references != nil || !(overlay.localizations ?? []).isEmpty
        return (category, hasContent ? overlay : nil)
    }

    static func validate(_ values: [VocabularyCategoryLocalization]) throws {
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
