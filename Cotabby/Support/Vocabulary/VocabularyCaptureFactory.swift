import Foundation

/// Converts already displayed values into a durable capture. Both the sentence panel and its
/// dictionary session call this pure adapter; it has no access to focus, AX or model services.
nonisolated enum VocabularyCaptureFactory {
    static func preview(_ presentation: LearningSentencePresentation, original: Bool? = nil) -> VocabularyCapture? {
        guard !presentation.isStale, !presentation.isError, !presentation.isTranslating,
              !presentation.source.isEmpty, !presentation.translation.isEmpty else { return nil }
        let original = original ?? (presentation.readingSource != nil)
        let text = original ? presentation.source : presentation.translation
        let meaning = original ? presentation.translation : presentation.source
        let language = original ? presentation.sourceLanguage : presentation.targetLanguage
        let otherLanguage = original ? presentation.targetLanguage : presentation.sourceLanguage
        let words = LearningUnitPolicy.words(in: text, language: language)
        let kind: VocabularyEntry.Kind = if words.count == 1 {
            .word
        } else if !presentation.targetIsSelection || text.last.map({ ".!?。！？".contains($0) }) == true {
            .sentence
        } else {
            .expression
        }
        var example: VocabularyExample?
        if original, let context = presentation.vocabularyContext {
            example = context
            // Only a whole-source translation is also a translation of the whole example.
            if context.text == text { example?.translation = meaning; example?.translationLanguage = otherLanguage }
        } else if kind == .sentence {
            example = VocabularyPolicy.example(text: text, ranges: [NSRange(location: 0, length: text.utf16.count)],
                language: language, startsAtBoundary: presentation.readingSource != .screenshot,
                endsAtBoundary: presentation.readingSource != .screenshot, app: presentation.vocabularyAppBundleIdentifier)
            example?.translation = meaning
            example?.translationLanguage = otherLanguage
        }
        example?.meaning = kind == .sentence ? "" : meaning
        example?.meaningLanguage = kind == .sentence ? nil : otherLanguage
        return VocabularyCapture(expression: text, dictionaryForm: text, language: language, kind: kind,
            meaning: meaning, meaningLanguage: otherLanguage, example: example)
    }

    static func unit(_ unit: LearningUnit, in presentation: LearningSentencePresentation) -> VocabularyCapture? {
        guard !presentation.isStale, !presentation.isError, !presentation.isTranslating,
              unit.ranges.allSatisfy({ VocabularyPolicy.valid($0, in: presentation.translation) }) else { return nil }
        var example = VocabularyPolicy.example(text: presentation.translation, ranges: unit.ranges,
            language: presentation.targetLanguage, startsAtBoundary: presentation.readingSource != .screenshot,
            endsAtBoundary: presentation.readingSource != .screenshot, app: presentation.vocabularyAppBundleIdentifier)
        if LearningUnitPolicy.words(in: presentation.translation, language: presentation.targetLanguage).count <= 1 {
            example = nil
        }
        if example?.text == presentation.translation {
            example?.translation = presentation.source
            example?.translationLanguage = presentation.sourceLanguage
        }
        // A larger alignment group is not a contextual definition of one word within it.
        // Only exact span correspondence can supply this meaning without another model call.
        let chunk = presentation.chunks.first { $0.targetRanges == unit.ranges }
        let meaning = chunk.map { LearningChunkDisplay.quote(presentation.source, ranges: $0.sourceRanges) } ?? ""
        example?.meaning = meaning
        example?.meaningLanguage = presentation.sourceLanguage
        let kind: VocabularyEntry.Kind = switch unit.kind {
        case .word: .word
        case .expression: .expression
        case .pattern: .pattern
        }
        return VocabularyCapture(expression: unit.kind == .pattern ? unit.query : unit.surface,
            dictionaryForm: unit.query, language: presentation.targetLanguage,
            kind: kind, meaning: meaning, meaningLanguage: presentation.sourceLanguage, example: example)
    }

    @MainActor static func definitions(_ result: LearningDictionarySession.Content) -> [VocabularyDefinition] {
        guard case .result(let result) = result else { return [] }
        switch result {
        case .systemText(let text):
            return [VocabularyDefinition(text: text, source: "macOS Dictionary", sourceURL: "", licenseURL: "")]
        case .notFound, .website: return []
        case .article(let article):
            return [VocabularyDefinition(text: article.text, source: article.sourceName,
                                         sourceURL: article.sourceURL, licenseURL: article.licenseURL)]
        case .entries(let entries): return entries.map { entry in
            VocabularyDefinition(text: entry.senses.flatMap(\.definitions).joined(separator: "\n"),
                source: entry.sourceName ?? "Wiktionary contributors / Kaikki", sourceURL: entry.sourceURL,
                licenseURL: entry.licenseURL ?? "https://creativecommons.org/licenses/by-sa/4.0/",
                licenseName: entry.licenseName ?? "CC BY-SA 4.0")
        }
        }
    }

    static func component(_ word: LearningDictionaryWord, unit: LearningUnit, capture: VocabularyCapture) -> VocabularyCapture? {
        guard unit.words.contains(word) else { return nil }
        var example = capture.example
        if let firstOriginal = unit.ranges.first, let firstLocal = example?.ranges.first, let text = example?.text {
            let offset = firstOriginal.location - firstLocal.location
            let range = NSRange(location: word.range.location - offset, length: word.range.length)
            guard VocabularyPolicy.valid(range, in: text), (text as NSString).substring(with: range) == word.text else { return nil }
            example?.ranges = [VocabularyTextRange(range)]
            example?.meaning = ""
            example?.meaningLanguage = nil
        } else { example = nil }
        return VocabularyCapture(expression: word.text, dictionaryForm: word.text, language: capture.language,
            kind: .word, example: example)
    }
}
