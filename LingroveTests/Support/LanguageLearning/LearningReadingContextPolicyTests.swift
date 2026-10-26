import Foundation
import Testing

@testable import Lingrove

/// Checks the pure boundary that validates a bounded AX context candidate before it becomes
/// an example. The reader owns remote AX acquisition; this suite proves the UTF-16 occurrence
/// and completeness rules without depending on a browser or Accessibility permission.
@Suite
struct LearningReadingContextPolicyTests {
    @Test
    func repeatedWordsKeepTheSuppliedOccurrenceOffset() {
        let text = "The same word appears, then the same word appears again."
        let source = text as NSString
        let firstRange = source.range(of: "word")
        let secondRange = source.range(of: "word", options: [], range: NSRange(
            location: NSMaxRange(firstRange), length: source.length - NSMaxRange(firstRange)))

        let first = example(
            text: text, range: firstRange, expected: "word",
            startsAtBoundary: true, endsAtBoundary: true, app: "com.example.editor")
        let second = example(
            text: text, range: secondRange, expected: "word",
            startsAtBoundary: true, endsAtBoundary: true, app: "com.example.editor")

        #expect(first?.ranges.first?.nsRange == firstRange)
        #expect(second?.ranges.first?.nsRange == secondRange)
        #expect(first?.ranges.first?.location != second?.ranges.first?.location)
    }

    @Test
    func selectedTrailingWhitespaceIsMatchedExactlyThenExcludedFromTheHighlight() {
        let text = "The team supported the plan."
        let source = text as NSString
        let selected = source.range(of: " supported ")
        let word = source.range(of: "supported")

        let example = example(
            text: text, range: selected, expected: " supported ",
            startsAtBoundary: true, endsAtBoundary: true, app: "com.example.editor")

        #expect(example?.text == text)
        #expect(example?.ranges.map(\.nsRange) == [word])
    }

    @Test
    func unicodeSelectionUsesUtf16OffsetsAndRejectsPartialComposedCharacters() {
        for grapheme in ["👩🏽‍💻", "e\u{301}"] {
            let text = "I saw \(grapheme) at work."
            let source = text as NSString
            let selected = source.range(of: grapheme)

            let whole = example(
                text: text, range: selected, expected: grapheme,
                startsAtBoundary: true, endsAtBoundary: true, app: "com.example.editor")
            let partial = NSRange(location: selected.location + 1, length: selected.length - 1)
            let split = example(
                text: text, range: partial, expected: grapheme,
                startsAtBoundary: true, endsAtBoundary: true, app: "com.example.editor")

            #expect(whole?.ranges.first?.nsRange == selected)
            #expect(split == nil)
        }
    }

    @Test
    func canonicallyEquivalentButDifferentUtf16SelectionIsRejected() {
        let text = "The café is open."
        let range = (text as NSString).range(of: "café")
        let differentlyComposed = "cafe\u{301}"

        // Swift String equality normalizes canonically equivalent spellings. AX offsets do not:
        // accepting this mismatch could extend the highlight into the following space.
        #expect("café" == differentlyComposed)
        #expect("café".utf16.count != differentlyComposed.utf16.count)
        #expect(example(
            text: text, range: range, expected: differentlyComposed,
            startsAtBoundary: true, endsAtBoundary: true, app: "com.example.editor") == nil)
    }

    @Test
    func selectionLargerThanTheConfiguredLimitIsRejectedWhole() {
        let selected = String(repeating: "a", count: LearningReadingContextPolicy.maximumSelectionUTF16 + 1)
        let range = NSRange(location: 0, length: (selected as NSString).length)

        #expect(example(
            text: selected, range: range, expected: selected,
            startsAtBoundary: true, endsAtBoundary: true, app: "com.example.editor") == nil)
    }

    @Test
    func contextMoreThanTheConfiguredWindowOnEitherSideIsRejected() {
        let left = String(repeating: "x", count: LearningReadingContextPolicy.maximumSurroundingUTF16 + 1)
        let leftText = left + " word."
        let leftRange = NSRange(location: (left as NSString).length + 1, length: 4)
        let right = String(repeating: "x", count: LearningReadingContextPolicy.maximumSurroundingUTF16 + 1)
        let rightText = "word. " + right
        let rightRange = NSRange(location: 0, length: 4)

        #expect(example(
            text: leftText, range: leftRange, expected: "word",
            startsAtBoundary: false, endsAtBoundary: true, app: "com.example.editor") == nil)
        #expect(example(
            text: rightText, range: rightRange, expected: "word",
            startsAtBoundary: true, endsAtBoundary: false, app: "com.example.editor") == nil)
    }

    @Test
    func croppedSentenceIsMarkedAsAFragment() {
        let text = "Earlier words around the selected word remain visible."
        let range = (text as NSString).range(of: "selected")

        let example = example(
            text: text, range: range, expected: "selected",
            startsAtBoundary: false, endsAtBoundary: true, app: "com.example.editor")

        #expect(example?.completeness == .fragment)
    }

    @Test
    func isolatedWordWithoutSentencePunctuationHasNoContext() {
        let text = "supported"
        let range = (text as NSString).range(of: text)

        let example = example(
            text: text, range: range, expected: text,
            startsAtBoundary: true, endsAtBoundary: true, app: "com.example.editor")

        #expect(example == nil)
    }
    private func example(text: String, range: NSRange, expected: String,
                         startsAtBoundary: Bool, endsAtBoundary: Bool, app: String) -> VocabularyExample? {
        LearningReadingContextPolicy.resolve(.init(text: text, target: range,
            left: startsAtBoundary ? .container : .crop, right: endsAtBoundary ? .container : .crop,
            method: .characters), expected: expected)?.example(app: app)
    }

}
