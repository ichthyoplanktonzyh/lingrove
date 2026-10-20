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
        // Freeze collection language when adopting an explanation: a mutable meaning must not
        // turn the blue fish back into an unsaved occurrence or duplicate that example on recapture.
        let meaningLanguage: LearningLanguage?
        if let identity = example.captureIdentity { meaningLanguage = identity.meaningLanguage } else {
            meaningLanguage = example.meaningLanguage
        }
        // Keep the exact text: normalized whitespace would change the interpretation of spans.
        return key([example.text, example.ranges.map { "\($0.location):\($0.length)" }.joined(separator: ","),
            example.translationLanguage?.rawValue ?? "", meaningLanguage?.rawValue ?? "", example.completeness.rawValue])
    }

    static func captureKey(_ capture: VocabularyCapture) -> String {
        let context = capture.example.map { exampleKey($0) } ?? "standalone:" + (capture.meaningLanguage?.rawValue ?? "unknown")
        return entryKey(capture) + ":" + context
    }

    static func contains(_ capture: VocabularyCapture, in entries: [VocabularyEntry]) -> Bool {
        guard let entry = entries.first(where: { entryKey($0) == entryKey(capture) }) else { return false }
        guard capture.example != nil else { return entry.standaloneMeanings.contains { $0.language == capture.meaningLanguage } }
        return entry.examples.contains { exampleKey($0) == exampleKey(capture.example) }
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
        if let index = document.entries.firstIndex(where: { entryKey($0) == entryKey(capture) }) {
            if capture.example == nil {
                if !document.entries[index].isSavedWithoutContext, document.entries[index].meaningOrigin != .user {
                    document.entries[index].meaning = capture.meaning
                    document.entries[index].meaningLanguage = capture.meaningLanguage
                    document.entries[index].meaningOrigin = .captured
                }
                document.entries[index].isSavedWithoutContext = true
                if !document.entries[index].standaloneMeanings.contains(where: { $0.language == capture.meaningLanguage }) {
                    document.entries[index].standaloneMeanings.append(
                        VocabularyMeaning(text: capture.meaning, language: capture.meaningLanguage))
                }
            }
            if let example = capture.example,
               !document.entries[index].examples.contains(where: { exampleKey($0) == exampleKey(example) }) {
                document.entries[index].examples.append(distinctExample(example, among: document.entries[index].examples))
            }
            if let record = capture.explanation { storeExplanation(record, in: &document.entries[index]) }
            // User-edited meanings/notes are never overwritten by a later model or dictionary.
            document.entries[index].updatedAt = now
            return document.entries[index].id
        }
        var entry = VocabularyEntry(id: UUID(), expression: capture.expression, dictionaryForm: capture.dictionaryForm,
            language: capture.language, kind: capture.kind, meaning: capture.example == nil ? capture.meaning : "",
            meaningLanguage: capture.meaningLanguage,
            note: "", tags: [],
            examples: capture.example.map { [$0] } ?? [], createdAt: now, updatedAt: now)
        entry.isSavedWithoutContext = capture.example == nil
        if capture.example == nil {
            entry.standaloneMeanings = [VocabularyMeaning(text: capture.meaning, language: capture.meaningLanguage)]
        }
        if let record = capture.explanation { storeExplanation(record, in: &entry) }
        document.entries.append(entry)
        return entry.id
    }

    /// Component captures can share one source receipt while pointing at different occurrences
    /// of the same word. Persisted usage identity belongs to the occurrence, not that receipt.
    /// Preserve existing IDs for editor reconciliation and assign only the colliding new usage
    /// a fresh ID; content-based deduplication has already rejected repeated saves above.
    private static func distinctExample(_ example: VocabularyExample, among existing: [VocabularyExample]) -> VocabularyExample {
        guard existing.contains(where: { $0.id == example.id }) else { return example }
        return VocabularyExample(id: UUID(), text: example.text, translation: example.translation,
            translationLanguage: example.translationLanguage, ranges: example.ranges, completeness: example.completeness,
            meaning: example.meaning, meaningLanguage: example.meaningLanguage, meaningOrigin: example.meaningOrigin,
            appBundleIdentifier: example.appBundleIdentifier, createdAt: example.createdAt, captureIdentity: example.captureIdentity)
    }

    static func matches(_ entry: VocabularyEntry, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let fields = [entry.expression, entry.dictionaryForm, entry.meaning, entry.note] + entry.tags +
            entry.standaloneMeanings.map(\.text) +
            entry.examples.flatMap { [$0.text, $0.translation, $0.meaning] }
        return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
    }

    /// Only an unchanged saved usage may receive a generated annotation. Notes and meanings are
    /// separate fields, and a late response cannot recreate a deleted word or edited example.
    static func accepts(_ record: LearningExplanationRecord, entry: VocabularyEntry) -> Bool {
        if entry.isSavedWithoutContext,
           LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, example: nil)) == record.input { return true }
        return entry.examples.contains {
            LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, example: $0)) == record.input
        }
    }
    static func storeExplanation(_ record: LearningExplanationRecord, in entry: inout VocabularyEntry) {
        guard LearningExplanationPolicy.isValid(record.input), LearningExplanationPolicy.isValid(record.result),
              accepts(record, entry: entry) else { return }
        var records = entry.explanations ?? []
        records.removeAll { $0.input == record.input && $0.language == record.language }
        records.append(record)
        entry.explanations = Array(records.suffix(24))
        // The captured occurrence remains the identity even if the explanation uses a different
        // output language. Draft meanings follow AI results; explicit user meanings do not.
        for index in entry.examples.indices {
            guard entry.examples[index].meaningOrigin != .user,
                  LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, example: entry.examples[index])) == record.input
            else { continue }
            entry.examples[index].captureIdentity = entry.examples[index].captureIdentity ??
                .init(meaningLanguage: entry.examples[index].meaningLanguage)
            entry.examples[index].meaning = record.result.meaning
            entry.examples[index].meaningLanguage = record.language
            entry.examples[index].meaningOrigin = .ai
        }
        if entry.isSavedWithoutContext, entry.meaningOrigin != .user,
           LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, example: nil)) == record.input {
            entry.meaning = record.result.meaning
            entry.meaningLanguage = record.language
            entry.meaningOrigin = .ai
        }
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
