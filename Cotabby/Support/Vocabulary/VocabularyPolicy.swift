import CryptoKit
import Foundation
import NaturalLanguage

/// Pure identity, context extraction and merge rules shared by cards, persistence and tests.
/// No model is asked to invent a sentence or meaning when the capture did not contain one.
nonisolated enum VocabularyPolicy {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func entryKey(_ capture: VocabularyCapture) -> String {
        key([capture.language.rawValue, capture.kind.rawValue, normalized(capture.expression)])
    }

    static func entryKey(_ entry: VocabularyEntry) -> String {
        key([entry.language.rawValue, entry.kind.rawValue, normalized(entry.expression)])
    }

    static func exampleKey(_ example: VocabularyExample?) -> String {
        guard let example else { return "no-context" }
        // The encountered text and exact spans are the usage identity. Annotation/translation
        // language is mutable content and cannot split a sense or turn an existing fish tail off.
        return key([example.text, example.ranges.map { "\($0.location):\($0.length)" }.joined(separator: ","),
            example.completeness.rawValue])
    }

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

    static func valid(_ range: NSRange, in text: String) -> Bool {
        range.location >= 0 && range.length > 0 && range.location <= text.utf16.count &&
            range.length <= text.utf16.count - range.location && Range(range, in: text) != nil &&
            (text as NSString).rangeOfComposedCharacterSequences(for: range) == range
    }

    /// The window's two completeness flags describe acquisition boundaries, not punctuation.
    /// A sentence touching an artificial AX/OCR crop edge stays explicitly a fragment.
    static func example(text: String, ranges: [NSRange], language: LearningLanguage,
                        startsAtBoundary: Bool = true, endsAtBoundary: Bool = true,
                        app: String? = nil) -> VocabularyExample? {
        guard !text.isEmpty, text.utf8.count <= 262_144, !ranges.isEmpty,
              ranges.allSatisfy({ valid($0, in: text) }) else { return nil }
        let lower = ranges.map(\.location).min() ?? 0
        let upper = ranges.map(NSMaxRange).max() ?? 0
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(language.naturalLanguage)
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
        return VocabularyExample(id: UUID(), text: (text as NSString).substring(with: scope), translation: "",
            ranges: ranges.map { VocabularyTextRange(NSRange(location: $0.location - scope.location, length: $0.length)) },
            completeness: complete ? .sentence : .fragment, meaning: "", appBundleIdentifier: app, createdAt: Date())
    }

    static func context(value: String, range: NSRange, language: LearningLanguage, app: String?) -> VocabularyExample? {
        guard valid(range, in: value), range.length <= 3_072 else { return nil }
        let text = value as NSString
        let start = max(0, range.location - 512), end = min(text.length, NSMaxRange(range) + 512)
        let window = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        return example(text: text.substring(with: window),
            ranges: [NSRange(location: range.location - window.location, length: range.length)], language: language,
            startsAtBoundary: window.location == 0, endsAtBoundary: NSMaxRange(window) == text.length, app: app)
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
            sense.isSavedWithoutContext && LearningExplanationPolicy.input(
                LearningExplanationPolicy.capture(entry, sense: sense, example: nil)) == record.input ||
                sense.examples.contains { LearningExplanationPolicy.input(
                    LearningExplanationPolicy.capture(entry, sense: sense, example: $0)) == record.input }
        }
    }

    static func storeExplanation(_ record: LearningExplanationRecord, in entry: inout VocabularyEntry) {
        guard LearningExplanationPolicy.isValid(record.input), LearningExplanationPolicy.isValid(record.result) else { return }
        for index in entry.senses.indices {
            let sense = entry.senses[index]
            if sense.isSavedWithoutContext, LearningExplanationPolicy.input(
                LearningExplanationPolicy.capture(entry, sense: sense, example: nil)) == record.input {
                append(record, to: &entry.senses[index].explanations)
                // A first general result can fill an empty summary. Later regeneration belongs
                // to the saved explanation; it cannot silently redefine the stable core meaning.
                if sense.meaning.isEmpty, sense.meaningOrigin != .user {
                    entry.senses[index].meaning = record.result.meaning
                    entry.senses[index].meaningLanguage = record.language
                    entry.senses[index].meaningOrigin = .ai
                }
            }
            for usage in sense.examples.indices {
                guard LearningExplanationPolicy.input(
                    LearningExplanationPolicy.capture(entry, sense: sense, example: sense.examples[usage])) == record.input
                else { continue }
                append(record, to: &entry.senses[index].examples[usage].explanations)
                if sense.examples[usage].meaningOrigin != .user {
                    entry.senses[index].examples[usage].meaning = record.result.meaning
                    entry.senses[index].examples[usage].meaningLanguage = record.language
                    entry.senses[index].examples[usage].meaningOrigin = .ai
                }
            }
        }
    }

    private static func append(_ record: LearningExplanationRecord, to records: inout [LearningExplanationRecord]) {
        records.removeAll { $0.input == record.input && $0.language == record.language }
        records.append(record)
        records = Array(records.suffix(24))
    }

    private static func key(_ parts: [String]) -> String {
        // Length framing prevents strings containing delimiters from aliasing another capture.
        let value = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum VocabularyError: LocalizedError {
    case invalidContent, unsupportedVersion, oversizedArchive, invalidArchive, editConflict
    var errorDescription: String? {
        switch self {
        case .invalidContent: String(localized: "This vocabulary item could not be verified.", table: "Vocabulary")
        case .unsupportedVersion: String(localized: "This notebook was created by a newer version of Lingrove.", table: "Vocabulary")
        case .oversizedArchive: String(localized: "The notebook exceeds the supported file size.", table: "Vocabulary")
        case .invalidArchive:
            String(localized: "The notebook could not be read. The original file has been preserved.", table: "Vocabulary")
        case .editConflict: String(localized: "This item changed while you were editing. Reopen it to continue.", table: "Vocabulary")
        }
    }
}
