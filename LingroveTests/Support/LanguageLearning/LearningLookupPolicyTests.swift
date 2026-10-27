import Foundation
import Testing
@testable import Lingrove

/// Prompt/parse tests establish the two-stage contract without trusting model output. Capture
/// routing fixtures use the same immutable values as AX/OCR, including an incomplete sentence.
struct LearningLookupPolicyTests {
    private func input(context: LearningExplanationContext = .sentence) -> LearningLookupInput {
        let sentence = context == .none ? "bank" : "He sat on the bank of the river."
        return .init(target: .init(target: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            context: sentence, ranges: [.init((sentence as NSString).range(of: "bank"))], contextKind: context),
            translationLanguage: .chinese)
    }

    @Test func firstTaskReturnsOnlyTheConsistentPairAndDetailsAreSeparatelyAnchored() throws {
        let input = input()
        let prompt = try LearningLookupPolicy.prompt(input, language: .japanese, total: 4_096, output: 512)
        #expect(prompt.contains("sentence_translation") && prompt.contains("Define only the original target"))
        #expect(prompt.contains("occurrence_ranges") && prompt.contains("\"location\":14"))
        #expect(prompt.contains(LearningLanguage.chinese.name) && prompt.contains(LearningLanguage.japanese.name))
        let basic = try LearningLookupPolicy.parse("{\"meaning\":\"河岸\",\"sentence_translation\":\"他坐在河岸上。\"}", input: input)
        #expect(basic.meaning == "河岸")
        let details = try LearningLookupPolicy.prompt(input, language: .chinese, total: 4_096, output: 1_024, basic: basic)
        #expect(details.contains("accepted_meaning") && details.contains("河岸") && details.contains("他坐在河岸上。"))
        #expect(details.contains("plain text, without JSON"))
        #expect(try LearningLookupPolicy.parseDetails("bank 是名词。") == "bank 是名词。")
    }

    @Test func incompleteOrExtraFieldsNeverBecomeBasicResults() {
        let input = input()
        for raw in ["{\"meaning\":\"河岸\"}", "{\"meaning\":\"河岸\",\"sentence_translation\":\"\"}",
                    "{\"meaning\":\"河岸\",\"sentence_translation\":\"译文\",\"explanation\":\"隐藏详解\"}"] {
            #expect(throws: (any Error).self) { try LearningLookupPolicy.parse(raw, input: input) }
        }
        for raw in ["", " \n ", "bad\u{0000}text", String(repeating: "x", count: 16_001),
                    String(repeating: " ", count: 24_001) + "text"] {
            #expect(throws: (any Error).self) { try LearningLookupPolicy.parseDetails(raw) }
        }
    }

    @Test func noContextDoesNotInventASentenceTranslationAndOversizedPairsFailWhole() throws {
        let input = input(context: .none)
        #expect(try LearningLookupPolicy.parse("{\"meaning\":\"银行；河岸\",\"sentence_translation\":\"\"}", input: input)
            .sentenceTranslation.isEmpty)
        #expect(throws: (any Error).self) {
            try LearningLookupPolicy.parse("{\"meaning\":\"河岸\",\"sentence_translation\":\"虚构句子\"}", input: input)
        }
        #expect(throws: (any Error).self) {
            try LearningLookupPolicy.prompt(self.input(), language: .chinese, total: 100, output: 90)
        }
    }

    @Test func capturedSentenceCoverageWinsOverPunctuationAndFragmentsStayLookups() throws {
        func selection(_ text: String, context: VocabularyExample?,
                       source: LearningReadingSource = .selection) -> LearningReadingSelection {
            .init(id: UUID(), text: text, processIdentifier: 1, bundleIdentifier: "fixture", anchor: .zero,
                source: source, context: context.flatMap { example in
                    guard let range = example.ranges.first?.nsRange else { return nil }
                    return LearningReadingContextPolicy.resolve(.init(text: example.text, target: range,
                        left: example.completeness == .sentence ? .container : .crop,
                        right: example.completeness == .sentence ? .container : .crop, method: .characters), expected: text)
                })
        }
        let sentence = "Please keep me posted"
        let full = VocabularyPolicy.example(text: sentence, ranges: [NSRange(location: 0, length: sentence.utf16.count)],
            language: .english, startsAtBoundary: true, endsAtBoundary: true)
        #expect(LearningReadingLookupPolicy.capture(selection(sentence, context: full), language: .english) == nil)
        for text in ["No.", "Run!", "Thanks.", " Thanks. ",
                     "Lingrove is built around two equally core capabilities that work together in any supported macOS text field:"] {
            let example = VocabularyPolicy.example(text: text, ranges: [NSRange(location: 0, length: text.utf16.count)],
                language: .english, startsAtBoundary: true, endsAtBoundary: true)
            #expect(LearningReadingLookupPolicy.capture(selection(text, context: example), language: .english) == nil)
            #expect(LearningReadingLookupPolicy.capture(selection(text, context: nil), language: .english) == nil)
        }
        let original = "Please keep me posted."
        var fragment = try #require(VocabularyPolicy.example(text: original,
            ranges: [(original as NSString).range(of: "me posted.")], language: .english))
        fragment.completeness = .fragment
        #expect(LearningReadingLookupPolicy.capture(selection("me posted.", context: fragment), language: .english)?.kind == .expression)
        #expect(LearningReadingLookupPolicy.capture(selection("bank", context: nil, source: .pointer), language: .english)?.kind == .word)
        #expect(LearningReadingLookupPolicy.capture(selection(" supported ", context: nil), language: .english)?.expression == "supported")
        #expect(LearningReadingLookupPolicy.capture(selection("bank:", context: nil), language: .english)?.kind == .word)
        let actual = "Lingrove is built around two equally core capabilities that work together in any supported macOS text field:"
        let context = VocabularyPolicy.example(text: actual,
            ranges: [(actual as NSString).range(of: "supported ")], language: .english)
        let result = LearningReadingLookupPolicy.capture(selection("supported ", context: context), language: .english)
        #expect(result?.kind == .word && result?.example?.text == actual)
    }
}
