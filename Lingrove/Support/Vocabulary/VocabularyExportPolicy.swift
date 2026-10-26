import Foundation

/// Pure projection keeps identity and context ownership while excluding live services and review
/// metadata. The archive calls it on one document snapshot before reading any selected media.
nonisolated enum VocabularyExportPolicy {
    static let maximumDataBytes = 64 * 1_024 * 1_024

    static func selected(_ entries: [VocabularyEntry], selections: [VocabularySelection]) throws -> [VocabularyEntry] {
        guard !selections.isEmpty else { throw VocabularyExportError.empty }
        var result: [VocabularyEntry] = [], seen = Set<VocabularySelection>()
        let source = Dictionary(grouping: entries, by: \.id)
        for selection in selections where seen.insert(selection).inserted {
            try Task.checkCancellation()
            guard let matches = source[selection.entryID], matches.count == 1, let entry = matches.first,
                  let sense = entry.senses.first(where: { $0.id == selection.senseID }) else { throw VocabularyExportError.changed }
            if let index = result.firstIndex(where: { $0.id == entry.id }) { result[index].senses.append(sense) } else {
                var copy = entry; copy.senses = [sense]; result.append(copy)
            }
        }
        return result
    }

    static func document(_ entries: [VocabularyEntry], configuration: VocabularyExportConfiguration) -> VocabularyExportDocument {
        let options = configuration
        return .init(version: entries.contains { $0.language == nil } ? 2 : 1, entries: entries.map { entry in
            .init(id: entry.id, expression: entry.expression, dictionaryForm: entry.dictionaryForm, language: entry.language,
                kind: entry.kind, senses: entry.senses.map { sense in
                    .init(id: sense.id, createdAt: sense.createdAt, meaning: options.meanings ? sense.meaning : nil,
                        meaningLanguage: options.meanings ? sense.meaningLanguage : nil,
                        otherMeanings: options.meanings ? otherValues(primary: sense.meaning, language: sense.meaningLanguage,
                            candidates: sense.standaloneMeanings + sense.alternateMeanings) : nil,
                        note: options.notes ? sense.note : nil, tags: options.notes ? sense.tags : nil,
                        examples: options.examples ? sense.examples.map { usage in
                            .init(id: usage.id, createdAt: usage.createdAt, text: usage.text, completeness: usage.completeness,
                                ranges: usage.ranges, translation: usage.translation, translationLanguage: usage.translationLanguage,
                                otherTranslations: otherValues(primary: usage.translation, language: usage.translationLanguage,
                                    candidates: usage.translationVariants), meaning: options.meanings ? usage.meaning : nil,
                                meaningLanguage: options.meanings ? usage.meaningLanguage : nil,
                                explanations: options.explanation ? explanations(usage.explanations) : nil)
                        } : nil,
                        explanations: options.explanation ? explanations(sense.explanations) : nil,
                        content: options.content ? (sense.content ?? []).map { block in
                            switch block.content {
                            case let .text(text): .init(id: block.id, text: text, image: nil, filename: nil, caption: nil)
                            case let .image(image, caption):
                                .init(id: block.id, text: nil, image: image,
                                    filename: (options.includesImages ? "images/" : "") + image.filename, caption: caption)
                            }
                        } : nil)
                })
        })
    }

    static func images(_ entries: [VocabularyEntry], configuration: VocabularyExportConfiguration) -> Set<VocabularyImageReference> {
        guard configuration.includesImages else { return [] }
        return Set(entries.flatMap { $0.senses.flatMap { VocabularyContentPolicy.images($0.content ?? []) } })
    }

    static func package(_ entries: [VocabularyEntry], configuration: VocabularyExportConfiguration) throws -> VocabularyExportPackage {
        try Task.checkCancellation()
        let document = document(entries, configuration: configuration)
        let data = try VocabularyExportFormatter.render(document, configuration: configuration)
        guard data.count <= maximumDataBytes else { throw VocabularyExportError.tooLarge }
        return .init(configuration: configuration, data: data,
            preview: VocabularyExportFormatter.preview(data, format: configuration.format), entryCount: entries.count,
            senseCount: entries.reduce(0) { $0 + $1.senses.count },
            exampleCount: configuration.examples && !configuration.isExpressionList ? entries.reduce(0) { $0 + $1.examples.count } : 0)
    }

    private static func explanations(_ records: [LearningExplanationRecord]) -> [VocabularyExportDocument.Explanation] {
        records.map { .init(language: $0.language, meaning: $0.result.meaning, detail: $0.result.explanation) }
    }

    /// Saved language variants may also contain the primary value. Export each exact text/language
    /// pair once, preserving distinct wordings rather than trying to merge meanings semantically.
    private static func otherValues(
        primary: String, language: LearningLanguage?, candidates: [VocabularyMeaning]
    ) -> [VocabularyMeaning] {
        var result: [VocabularyMeaning] = []
        for candidate in candidates where !candidate.text.isEmpty {
            guard candidate.text != primary || candidate.language != language else { continue }
            if !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }
}
