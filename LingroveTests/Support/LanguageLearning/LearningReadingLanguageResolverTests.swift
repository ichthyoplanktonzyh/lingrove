import Foundation
import NaturalLanguage
import Testing
@testable import Lingrove

/// Scores are injected for boundary cases; real short-word regressions ensure the coordinator's
/// reading policy also works with the system recognizer rather than a pre-filled English hint.
struct LearningReadingLanguageResolverTests {
    @Test(arguments: ["focus", "bank", "chat", "supported"])
    func shortWordsBorrowTheirCapturedSentence(_ word: String) {
        let result = LearningReadingLanguageResolver.resolve(text: word, context: "Please explain the word \(word) in this sentence.")
        #expect(result.language == .english)
        #expect(result.evidence == .context)
    }

    @Test func theReportedReadmeExampleResolvesWithoutAHint() {
        let result = LearningReadingLanguageResolver.resolve(text: "focus", context:
            "Listen to sentences or expressions without losing typing focus using macOS system voices.")
        #expect(result.language == .english)
        #expect(result.evidence == .context)
    }

    @Test func aConfidentSharedWordDoesNotOverrideItsSentence() {
        let result = LearningReadingLanguageResolver.resolve(text: "chat", context: "Nous parlons du chat dans cette phrase.",
            hint: .english) { sample in sample == "chat" ? [.english: 0.99] : [.french: 0.98] }
        #expect(result.language == .french)
        #expect(result.evidence == .context)
    }

    @Test func aCompleteSelectionWinsOverContextAndHint() {
        var samples: [String] = []
        let text = "Please read this sentence."
        let result = LearningReadingLanguageResolver.resolve(text: text, context: "中文段落中的引文。", hint: .chinese) { sample in
            samples.append(sample)
            return [.english: 0.99]
        }
        #expect(result.language == .english)
        #expect(result.evidence == .selection)
        #expect(samples == [text])
    }

    @Test(arguments: [
        ("focus", "这是有关 focus 的中文说明。", LearningLanguage.chinese),
        ("你好", "We say 你好 to greet someone.", .english),
        ("ありがとう", "We say ありがとう to thank someone.", .english)
    ])
    func aDifferentScriptCannotRelabelTheSelectedWord(text: String, context: String, hint: LearningLanguage) {
        let result = LearningReadingLanguageResolver.resolve(text: text, context: context, hint: hint) { sample in
            if sample == text { return [:] }
            return [hint.naturalLanguage: 0.99]
        }
        #expect(result.language == nil)
        #expect(result.evidence == .unavailable)
    }

    @Test(arguments: [
        ("你好", LearningLanguage.chinese), ("銀行", .traditionalChinese), ("ありがとう", .japanese),
        ("한국", .korean), ("привет", .russian), ("नमस्ते", .hindi), ("مرحبا", .arabic), ("bonjour", .french)
    ])
    func compatibleCaptureHintsRemainAvailable(text: String, language: LearningLanguage) {
        let result = LearningReadingLanguageResolver.resolve(text: text, hint: language, recognize: { _ in [:] })
        #expect(result.language == language)
        #expect(result.evidence == .hint)
    }

    @Test func distinctiveWordsStillWorkWithoutContext() {
        let result = LearningReadingLanguageResolver.resolve(text: "supported", recognize: { _ in [.english: 0.95] })
        #expect(result.language == .english)
        #expect(result.evidence == .selection)
    }

    @Test func unavailableEvidenceIsNotReplacedWithAnArbitraryLanguage() {
        let result = LearningReadingLanguageResolver.resolve(text: "focus", recognize: { _ in [.english: 0.19, .dutch: 0.15] })
        #expect(result.language == nil)
        #expect(result.evidence == .unavailable)
    }

    @Test(arguments: [false, true])
    func confidentUnsupportedEvidenceStopsBeforeAFallbackHint(_ completeSelection: Bool) {
        let result = LearningReadingLanguageResolver.resolve(text: completeSelection ? "Det här är en svensk mening." : "bank",
            context: "Vi sitter vid en bank och pratar.", hint: .english, recognize: { _ in [.swedish: 0.99] })
        #expect(result.language == nil)
        #expect(result.evidence == (completeSelection ? .selection : .context))
    }

    @Test func anUnsupportedContextCannotHideASelectionInAnotherScript() {
        let result = LearningReadingLanguageResolver.resolve(text: "你好", context: "Vi säger 你好 när vi hälsar.", hint: .english) {
            sample in sample == "你好" ? [.simplifiedChinese: 0.99] : [.swedish: 0.99]
        }
        #expect(result.language == .chinese)
        #expect(result.evidence == .selection)
    }

    @Test(arguments: ["", "123 !", " \n "])
    func nonLanguageSelectionsDoNotBorrowAContext(_ text: String) {
        let result = LearningReadingLanguageResolver.resolve(text: text, context: "Please read this sentence.", hint: .english) { _ in
            Issue.record("Non-language selections must not invoke recognition")
            return [.english: 1]
        }
        #expect(result.language == nil)
    }

    @Test func invalidAndAmbiguousScoresRemainUnknown() {
        for scores: [NLLanguage: Double] in [[.english: .nan], [.english: .infinity], [.english: 1.2],
                                            [.english: 0.54], [.english: 0.7, .french: 0.6]] {
            #expect(LearningReadingLanguageResolver.resolve(text: "Some text with several words.",
                recognize: { _ in scores }).language == nil)
        }
    }

    @Test func identicalContextDoesNotAddLanguageEvidence() {
        var calls = 0
        let result = LearningReadingLanguageResolver.resolve(text: "focus ", context: " focus ") { _ in
            calls += 1
            return [:]
        }
        #expect(result.language == nil)
        #expect(calls == 1)
    }

    @Test func bothSamplesAreBounded() {
        var lengths: [Int] = []
        _ = LearningReadingLanguageResolver.resolve(text: String(repeating: "a", count: 3_000),
            context: String(repeating: "b", count: 3_000)) { sample in
            lengths.append(sample.count)
            return [:]
        }
        #expect(lengths == [600, 600])
    }
}
