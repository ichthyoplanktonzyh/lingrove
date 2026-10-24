import Foundation
import Testing
@testable import Lingrove

nonisolated struct VocabularyPolicyTests {
    @Test func repeatedWordKeepsClickedOccurrence() throws {
        let text = "I saw a bat near the bat." as NSString
        let range = text.range(of: "bat", options: .backwards)
        let example = try #require(VocabularyPolicy.example(text: text as String, ranges: [range],
            language: .english))
        #expect(example.ranges == [VocabularyTextRange(range)])
        #expect(example.completeness == .sentence)
    }

    @Test func emojiBeforeWordPreservesUTF16Range() throws {
        let text = "🐟 Please keep me posted."
        let range = (text as NSString).range(of: "keep me posted")
        let example = try #require(VocabularyPolicy.example(text: text, ranges: [range],
            language: .english))
        let saved = try #require(example.ranges.first)
        #expect((example.text as NSString).substring(with: saved.nsRange) == "keep me posted")
    }

    @Test func extractionKeepsOnlyContainingSentence() throws {
        let text = "It was late. Please keep me posted. Thank you."
        let range = (text as NSString).range(of: "posted")
        let example = try #require(VocabularyPolicy.example(text: text, ranges: [range],
            language: .english))
        #expect(example.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Please keep me posted.")
        #expect((example.text as NSString).substring(with: example.ranges[0].nsRange) == "posted")
    }

    @Test func croppedSentenceRemainsFragment() throws {
        let example = try #require(VocabularyPolicy.example(text: "keep me posted", ranges: [NSRange(location: 0, length: 4)],
            language: .english, startsAtBoundary: false, endsAtBoundary: false))
        #expect(example.completeness == .fragment)
    }

    @Test func disjointPatternRangesSurviveExtraction() throws {
        let text = "Please keep me posted on the progress."
        let spans = ["keep", "posted"].map { (text as NSString).range(of: $0) }
        let example = try #require(VocabularyPolicy.example(text: text, ranges: spans,
            language: .english))
        #expect(example.ranges.map { (example.text as NSString).substring(with: $0.nsRange) } == ["keep", "posted"])
    }

    @Test func invalidAndSplitSurrogateRangesAreRejected() {
        #expect(!VocabularyPolicy.valid(NSRange(location: Int.max, length: 2), in: "Hi"))
        #expect(!VocabularyPolicy.valid(NSRange(location: 1, length: 1), in: "🐟Hi"))
        #expect(VocabularyPolicy.example(text: "Hi", ranges: [NSRange(location: 99, length: 2)], language: .english) == nil)
    }

    @Test func duplicateCaptureDoesNotCreateAnotherEntryOrExample() throws {
        var document = VocabularyDocument()
        let capture = try fixture()
        let first = try VocabularyPolicy.save(capture, in: &document, now: Date())
        let second = try VocabularyPolicy.save(capture, in: &document, now: Date())
        #expect(first == second)
        #expect(document.entries.count == 1 && document.entries[0].examples.count == 1)
    }

    @Test func differentContextsKeepIndividualMeaningsAndUserNotes() throws {
        var document = VocabularyDocument()
        var first = try fixture()
        first.example?.meaning = "第一种含义"
        _ = try VocabularyPolicy.save(first, in: &document, now: Date())
        document.entries[0].senses[0].note = "User note"
        var second = try fixture(text: "They posted the letter.")
        second.example?.meaning = "第二种含义"
        _ = try VocabularyPolicy.save(second, in: &document, now: Date())
        #expect(document.entries.count == 1)
        #expect(document.entries[0].examples.map(\.meaning) == ["第一种含义", "第二种含义"])
        #expect(document.entries[0].senses[0].note == "User note")
        #expect(VocabularyPolicy.matches(document.entries[0], query: "第二种 User"))
    }

    @Test func boundedDraftContextDoesNotPersistUnrelatedDraft() throws {
        let value = String(repeating: "Earlier. ", count: 500) + "Please keep me posted. " + String(repeating: "Later. ", count: 500)
        let range = (value as NSString).range(of: "posted")
        let context = try #require(VocabularyPolicy.context(value: value, range: range, language: .english, app: "test.app"))
        #expect(context.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Please keep me posted.")
        #expect(context.appBundleIdentifier == "test.app")
    }

    @Test func translationsInDifferentLanguagesKeepOneUsageAndBothVariants() throws {
        var document = VocabularyDocument()
        var first = try fixture(), second = try fixture()
        first.example?.translationLanguage = .chinese
        first.example?.translation = "请随时告诉我。"
        second.example?.translationLanguage = .spanish
        second.example?.translation = "Mantenme informado."
        _ = try VocabularyPolicy.save(first, in: &document, now: Date())
        _ = try VocabularyPolicy.save(second, in: &document, now: Date())
        #expect(document.entries.count == 1)
        #expect(document.entries[0].examples.count == 1)
        #expect(document.entries[0].examples[0].translationVariants.count == 2)
    }

    @Test func reconciledRangesReanchorExpressionAfterExampleTextEdit() {
        let updatedText = "🐟 Please keep me posted about the schedule."
        let ranges = VocabularyPolicy.reconciledRanges(
            in: updatedText,
            expression: "Keep me posted",
            dictionaryForm: "keep someone posted"
        )
        #expect(ranges.count == 1)
        #expect((updatedText as NSString).substring(with: ranges[0].nsRange) == "keep me posted")
    }

    private func fixture(text: String = "Please keep me posted.") throws -> VocabularyCapture {
        let example = try #require(VocabularyPolicy.example(text: text, ranges: [(text as NSString).range(of: "posted")],
            language: .english))
        return VocabularyCapture(expression: "posted", dictionaryForm: "post", language: .english, kind: .word, example: example)
    }
}
