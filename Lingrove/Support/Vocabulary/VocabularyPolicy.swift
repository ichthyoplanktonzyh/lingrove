import LingroveTextRules
import LingroveNotebook
import Foundation
import NaturalLanguage

/// Pure identity, context extraction and merge rules shared by cards, persistence and tests.
/// No model is asked to invent a sentence or meaning when the capture did not contain one.
nonisolated enum VocabularyPolicy {
    static func normalized(_ text: String) -> String { VocabularyIdentityPolicy.normalized(text) }

    static func entryKey(_ capture: VocabularyCapture) -> String {
        VocabularyIdentityPolicy.entryKey(expression: capture.expression, language: capture.language, kind: capture.kind)
    }

    static func entryKey(_ entry: VocabularyEntry) -> String { VocabularyIdentityPolicy.entryKey(entry) }

    static func exampleKey(_ example: VocabularyExample?) -> String { VocabularyIdentityPolicy.exampleKey(example) }

    static func captureKey(_ capture: VocabularyCapture) -> String {
        entryKey(capture) + ":" + (capture.example.map { exampleKey($0) } ?? "standalone")
    }

    static func contains(_ capture: VocabularyCapture, in entries: [VocabularyEntry]) -> Bool {
        guard let entry = entries.first(where: { entryKey($0) == entryKey(capture) }) else { return false }
        return VocabularySensePolicy.destination(capture, in: entry) != nil
    }

    static func validate(_ capture: VocabularyCapture) throws {
        guard !normalized(capture.expression).isEmpty, capture.expression.utf8.count <= 262_144 else {
            throw VocabularyError.invalidContent
        }
        if let example = capture.example {
            guard !example.text.isEmpty, example.text.utf8.count <= 262_144,
                  example.ranges.allSatisfy({ valid($0.nsRange, in: example.text) }) else {
                throw VocabularyError.invalidContent
            }
        }
    }

    static func valid(_ range: NSRange, in text: String) -> Bool { UTF16TextRangePolicy.isValid(range, in: text) }

    /// Reconciles an example's highlight spans after the user edits `example.text` or `expression`
    /// in the notebook editor. Existing translations, translation variants, and contextual meanings
    /// remain intact while valid occurrences of the expression (or dictionary form) are re-anchored.
    static func reconciledRanges(in text: String, expression: String, dictionaryForm: String = "") -> [VocabularyTextRange] {
        let candidates = [normalized(expression), normalized(dictionaryForm)].filter { !$0.isEmpty }
        guard !text.isEmpty, !candidates.isEmpty else { return [] }
        let nsText = text as NSString
        for needle in candidates {
            var matches: [VocabularyTextRange] = []
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.location < nsText.length {
                let found = nsText.range(
                    of: needle,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard found.location != NSNotFound, found.length > 0 else { break }
                let composed = nsText.rangeOfComposedCharacterSequences(for: found)
                if valid(composed, in: text) {
                    matches.append(VocabularyTextRange(composed))
                }
                let nextLocation = NSMaxRange(found)
                guard nextLocation > searchRange.location, nextLocation <= nsText.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }
            if !matches.isEmpty { return matches }
        }
        return []
    }

    /// The window's two completeness flags describe acquisition boundaries, not punctuation.
    /// A sentence touching an artificial AX/OCR crop edge stays explicitly a fragment.
    static func example(text: String, ranges: [NSRange], language: LearningLanguage?,
                        startsAtBoundary: Bool = true, endsAtBoundary: Bool = true,
                        app: String? = nil) -> VocabularyExample? {
        guard !text.isEmpty, text.utf8.count <= 262_144, !ranges.isEmpty,
              ranges.allSatisfy({ valid($0, in: text) }) else { return nil }
        let lower = ranges.map(\.location).min() ?? 0
        let upper = ranges.map(NSMaxRange).max() ?? 0
        let tokenizer = NLTokenizer(unit: .sentence)
        if let language { tokenizer.setLanguage(language.naturalLanguage) }
        tokenizer.string = text
        var sentence: NSRange?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let candidate = NSRange(range, in: text)
            if candidate.location <= lower && NSMaxRange(candidate) >= upper { sentence = candidate; return false }
            return true
        }
        let scope = sentence ?? NSRange(location: 0, length: text.utf16.count)
        let complete = sentence != nil && (scope.location > 0 || startsAtBoundary) &&
            (NSMaxRange(scope) < text.utf16.count || endsAtBoundary)
        return VocabularyExample(id: UUID(), sourceKind: .captured, text: (text as NSString).substring(with: scope), translation: "",
            ranges: ranges.map { VocabularyTextRange(NSRange(location: $0.location - scope.location, length: $0.length)) },
            completeness: complete ? .sentence : .fragment, meaning: "", appBundleIdentifier: app, createdAt: Date())
    }

    static func context(value: String, range: NSRange, language: LearningLanguage?, app: String?) -> VocabularyExample? {
        guard valid(range, in: value), range.length <= 3_072 else { return nil }
        let text = value as NSString
        let start = max(0, range.location - 512), end = min(text.length, NSMaxRange(range) + 512)
        let window = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        return example(text: text.substring(with: window),
            ranges: [NSRange(location: range.location - window.location, length: range.length)], language: language,
            startsAtBoundary: window.location == 0, endsAtBoundary: NSMaxRange(window) == text.length, app: app)
    }

    /// Prepare one saved entry. The engine reconstructs its evidence from its own current
    /// SQL state, avoiding a round trip through every entry for one capture.
    static func entryForSave(_ input: VocabularyCapture, in document: VocabularyDocument, now: Date)
        throws -> VocabularyEntry {
        try validate(input)
        var capture = input
        let header = document.catalog.first { entryKey($0) == entryKey(capture) }
        var entry: VocabularyEntry
        if let header, let joined = VocabularyNotebookProjection.entry(header.id, in: document) { entry = joined } else {
            guard capture.senseID == nil else { throw VocabularyError.invalidContent }
            entry = .init(id: UUID(), expression: capture.expression, dictionaryForm: capture.dictionaryForm,
                language: capture.language, kind: capture.kind, senses: [], createdAt: now, updatedAt: now)
        }
        let oldSenses = Set(entry.senses.map(\.id))
        if let example = capture.example, document.interpretations.contains(where: {
            $0.id == example.id && $0.status == .accepted && $0.senseID.map { !oldSenses.contains($0) } == true
        }) { capture.example = example.copiedWithNewID() }
        try VocabularySensePolicy.save(capture, in: &entry, now: now)
        return entry
    }

    static func save(_ capture: VocabularyCapture, in document: inout VocabularyDocument, now: Date) throws -> UUID {
        try validate(capture)
        var capture = capture
        if let example = capture.example, document.entries.contains(where: {
            entryKey($0) != entryKey(capture) && $0.examples.contains { $0.id == example.id }
        }) { capture.example = example.copiedWithNewID() }
        let index: Int
        if let existing = document.entries.firstIndex(where: { entryKey($0) == entryKey(capture) }) { index = existing } else {
            guard capture.senseID == nil else { throw VocabularyError.invalidContent }
            document.entries.append(VocabularyEntry(id: UUID(), expression: capture.expression, dictionaryForm: capture.dictionaryForm,
                language: capture.language, kind: capture.kind, senses: [], createdAt: now, updatedAt: now))
            index = document.entries.count - 1
        }
        try VocabularySensePolicy.save(capture, in: &document.entries[index], now: now)
        return document.entries[index].id
    }

    static func matches(_ entry: VocabularyEntry, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        var fields = [entry.expression, entry.dictionaryForm]
        for sense in entry.senses {
            fields += [sense.meaning, sense.note] + sense.tags + sense.standaloneMeanings.map(\.text) + sense.alternateMeanings.map(\.text)
            fields += (sense.content ?? []).map { block in
                switch block.content {
                case let .text(value): value.text
                case let .image(_, caption): caption
                }
            }
            for example in sense.examples {
                fields += [example.text, example.translation, example.meaning]
                fields += example.translationVariants.map(\.text)
            }
        }
        return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
    }

    /// A saved explanation can follow a moved usage, but cannot recreate a removed/edited one.
    /// The owner is resolved from current data at commit time rather than a captured sense index.
    static func accepts(_ record: LearningExplanationRecord, entry: VocabularyEntry) -> Bool {
        entry.senses.contains { sense in
            sense.supportsGeneralExplanation && LearningExplanationPolicy.input(
                LearningExplanationPolicy.capture(entry, sense: sense, example: nil)) == record.input ||
                sense.examples.contains { LearningExplanationPolicy.input(
                    LearningExplanationPolicy.capture(entry, sense: sense, example: $0)) == record.input }
        }
    }

    static func storeExplanation(_ record: LearningExplanationRecord, in entry: inout VocabularyEntry) {
        guard LearningExplanationPolicy.isValid(record.input), LearningExplanationPolicy.isValid(record.result) else { return }
        for index in entry.senses.indices {
            let sense = entry.senses[index]
            if sense.supportsGeneralExplanation, LearningExplanationPolicy.input(
                LearningExplanationPolicy.capture(entry, sense: sense, example: nil)) == record.input {
                storeGeneralExplanation(record, in: &entry.senses[index])
            }
            for usage in sense.examples.indices {
                guard LearningExplanationPolicy.input(
                    LearningExplanationPolicy.capture(entry, sense: sense, example: sense.examples[usage])) == record.input
                else { continue }
                // A delayed answer may fill its original, still-unedited sense. Once senses
                // have been merged, only the retained destination's authored content is used.
                fillExplanation(record, in: &entry.senses[index])
                append(record, to: &entry.senses[index].examples[usage].explanations)
                if sense.examples[usage].meaningOrigin != .user {
                    entry.senses[index].examples[usage].meaning = record.result.meaning
                    entry.senses[index].examples[usage].meaningLanguage = record.language
                    entry.senses[index].examples[usage].meaningOrigin = .ai
                }
            }
        }
    }

    /// The caller has already resolved and checked this exact sense's input. A definition
    /// supplied by the user remains authoritative; only an empty, unowned summary can be filled.
    static func storeGeneralExplanation(_ record: LearningExplanationRecord, in sense: inout VocabularySense) {
        guard LearningExplanationPolicy.isValid(record.input), LearningExplanationPolicy.isValid(record.result) else { return }
        append(record, to: &sense.explanations)
        fillExplanation(record, in: &sense)
    }

    /// nil is an untouched explanation; [] is an explicitly cleared editor value. Filling
    /// only the former keeps delayed lookups from undoing a user's edit or a merge decision.
    private static func fillExplanation(_ record: LearningExplanationRecord, in sense: inout VocabularySense) {
        guard sense.mergedFrom.isEmpty else { return }
        if sense.meaning.isEmpty, sense.meaningOrigin != .user {
            sense.meaning = record.result.meaning
            sense.meaningLanguage = record.language
            sense.meaningOrigin = .ai
        }
        if sense.content == nil {
            sense.content = [.init(id: record.id, content: .text(.init(text: record.result.explanation)))]
        }
    }

    private static func append(_ record: LearningExplanationRecord, to records: inout [LearningExplanationRecord]) {
        records.removeAll { $0.input == record.input && $0.language == record.language }
        records.append(record)
        records = Array(records.suffix(24))
    }

}

/// Preserve the app error name while package decoding throws the same error identity.
typealias VocabularyError = LingroveNotebook.VocabularyError
