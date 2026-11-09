import Foundation
import LingroveTextRules

/// Both native browsers search the same saved fields. Search only projects data: a matching
/// string never adopts a proposal, creates a semantic edge, or changes the language of a source.
public nonisolated enum VocabularyNotebookQuery {
    public static func matches(_ entry: VocabularyEntry, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        var fields = [entry.expression, entry.dictionaryForm]
        for sense in entry.senses {
            fields += [sense.meaning, sense.note] + sense.tags + sense.standaloneMeanings.map(\.text) + sense.alternateMeanings.map(\.text)
            fields += (sense.content ?? []).map { block in
                switch block.content { case .text(let value): value.text; case .image(_, let caption): caption }
            }
            fields += sense.explanations.flatMap { [$0.result.meaning, $0.result.explanation] }
            for example in sense.examples {
                fields += [example.text, example.translation, example.meaning] + example.translationVariants.map(\.text)
                fields += example.explanations.flatMap { [$0.result.meaning, $0.result.explanation] }
            }
        }
        return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
    }

    public static func matches(_ category: VocabularyCategory, term: String) -> Bool {
        category.labels.contains { $0.text.localizedStandardContains(term) } || category.definition.localizedStandardContains(term)
            || category.localizations.contains {
                ($0.name?.localizedStandardContains(term) ?? false) || ($0.definition?.localizedStandardContains(term) ?? false)
            }
    }

    public static func categoryTitle(_ category: VocabularyCategory, in index: VocabularyClassificationIndex,
                                     interfaceIdentifiers: [String] = Bundle.main.preferredLocalizations) -> String {
        let value = VocabularyClassificationPolicy.effective(category, in: index)
        var preferences = interfaceIdentifiers.prefix(1).map(VocabularyCategoryLocalizationRules.normalized)
        if let first = preferences.first, let language = VocabularyMeaningLabelRules.language(for: first) {
            preferences.append(VocabularyCategoryLocalizationRules.normalized(language.rawValue))
        }
        preferences.append("en")
        let rows = Dictionary(value.localizations.map { (VocabularyCategoryLocalizationRules.normalized($0.language), $0) },
            uniquingKeysWith: { first, _ in first })
        for preference in preferences { if let name = rows[preference]?.name { return name } }
        return VocabularyMeaningLabelRules.label(in: value.labels,
            languages: preferences.compactMap(VocabularyMeaningLabelRules.language(for:)))?.text ?? ""
    }

    public static func senseTitle(_ sense: VocabularySense) -> String {
        if !sense.meaning.isEmpty { return sense.meaning }
        for block in sense.content ?? [] {
            if case .text(let text) = block.content, !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text.text }
        }
        if !VocabularyContentPolicy.images(sense.content ?? []).isEmpty { return String(localized: "Image explanation", table: "Vocabulary") }
        return String(localized: "Meaning pending", table: "Vocabulary")
    }

    public static func hasMultipleLanguages(_ entries: [VocabularyEntry]) -> Bool {
        Set(entries.map { $0.language?.rawValue ?? "und" }).count > 1
    }

    public static func expressionTitle(_ entry: VocabularyEntry, includeLanguage: Bool) -> String {
        guard includeLanguage else { return entry.expression }
        let name = entry.language.map { language in
            Locale(identifier: language.rawValue).localizedString(forIdentifier: language.rawValue) ?? language.rawValue
        } ?? String(localized: "Unspecified", table: "Learning")
        return entry.expression + " · " + name
    }

    /// Imported examples keep all supplied text. Literal expression matches are annotated in
    /// UTF-16 only after composed-character expansion; an unmatched phrase remains unhighlighted.
    public static func reconciledRanges(in text: String, expression: String, dictionaryForm: String = "") -> [VocabularyTextRange] {
        let candidates = [expression, dictionaryForm].map(VocabularyIdentityPolicy.normalized).filter { !$0.isEmpty }
        let source = text as NSString
        for candidate in candidates {
            var matches: [VocabularyTextRange] = [], cursor = 0
            while cursor < source.length {
                let found = source.range(of: candidate, options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: cursor, length: source.length - cursor))
                guard found.location != NSNotFound, found.length > 0 else { break }
                let composed = source.rangeOfComposedCharacterSequences(for: found)
                if UTF16TextRangePolicy.isValid(composed, in: text) { matches.append(.init(composed)) }
                cursor = NSMaxRange(found)
            }
            if !matches.isEmpty { return matches }
        }
        return []
    }
}
