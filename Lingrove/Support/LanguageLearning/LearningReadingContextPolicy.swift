import Foundation

/// Reduces a bounded AX window into one immutable usage. OS adapters supply exact UTF-16 spans;
/// this rule never searches for matching spelling, so repeated occurrences retain their identity.
nonisolated enum LearningReadingContextPolicy {
    static let maximumSelectionUTF16 = 3_072
    static let surroundingUTF16 = 512

    // The six values form one captured range plus its independent crop-boundary evidence.
    // swiftlint:disable:next function_parameter_count
    static func example(text: String, range: NSRange, expected: String, startsAtBoundary: Bool,
                        endsAtBoundary: Bool, app: String) -> VocabularyExample? {
        guard !expected.isEmpty, expected.utf16.count <= maximumSelectionUTF16,
              range.length == expected.utf16.count, VocabularyPolicy.valid(range, in: text),
              (text as NSString).substring(with: range).utf16.elementsEqual(expected.utf16),
              range.location <= surroundingUTF16, text.utf16.count - NSMaxRange(range) <= surroundingUTF16 else { return nil }
        // Browser double-click selection often includes a following space. Keep the raw receipt
        // for staleness checks, but highlight only the actual word in the captured sentence.
        let leading = expected.prefix(while: \.isWhitespace).utf16.count
        let trimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRange = NSRange(location: range.location + leading, length: trimmed.utf16.count)
        guard !trimmed.isEmpty, VocabularyPolicy.valid(targetRange, in: text) else { return nil }
        let language = LearningLanguage.detect(in: text) ?? .english
        let isolatedWord = text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed &&
            LearningUnitPolicy.words(in: trimmed, language: language).count == 1
        if isolatedWord, trimmed.last.map({ ".!?。！？".contains($0) }) != true { return nil }
        return VocabularyPolicy.example(text: text, ranges: [targetRange], language: language,
            startsAtBoundary: startsAtBoundary, endsAtBoundary: endsAtBoundary, app: app)
    }
}
