import Foundation
import Testing
@testable import Lingrove

/// Pure fixtures pin exact occurrences, bounded references and complete structured output.
nonisolated struct LearningExplanationPolicyTests {
    private func input(target: String = "know", context: String = "Let me know when it is ready.",
                       ranges: [NSRange]? = nil) -> LearningExplanationInput {
        .init(target: target, dictionaryForm: target, language: .english, kind: .word, context: context,
            ranges: (ranges ?? [(context as NSString).range(of: target)]).map(VocabularyTextRange.init))
    }

    @Test(arguments: [LearningExplanationContext.sentence, .fragment, .unknown, .none])
    func evidenceScopeControlsTheTaskWithoutForcingOneSense(_ scope: LearningExplanationContext) throws {
        let context = scope == .none ? "bat" : "I saw a bat near the window."
        var capture = VocabularyCapture(expression: "bat", dictionaryForm: "bat", language: .english, kind: .word)
        if scope != .none {
            capture.example = VocabularyPolicy.example(text: context, ranges: [(context as NSString).range(of: "bat")], language: .english)
            capture.example?.completeness = VocabularyExample.Completeness(rawValue: scope.rawValue) ?? .unknown
        }
        let input = LearningExplanationPolicy.input(capture)
        #expect(input.contextKind == scope)
        let prompt = try LearningExplanationPolicy.prompt(input, language: .chinese, total: 8_192, output: 1_024)
        #expect(prompt.contains("\"contextCompleteness\":\"\(scope.rawValue)\""))
        #expect(!prompt.contains("at most three key points"))
        if scope == .none {
            #expect(prompt.contains("general definition or common senses") && prompt.contains("define_target"))
        } else if scope == .fragment {
            #expect(prompt.contains("possible senses"))
        } else if scope == .unknown {
            #expect(prompt.contains("boundaries are unverified") && !prompt.contains("Only a context fragment"))
        } else { #expect(prompt.contains("complete original sentence")) }
        if let receipt = input.occurrenceIdentity { #expect(!prompt.contains(receipt)) }
        let ambiguous = "{\"meaning\":\"可能是蝙蝠，也可能指球棒\",\"explanation\":\"片段不足以唯一确定词义。\"}"
        #expect(try LearningExplanationPolicy.parse(ambiguous).meaning.contains("可能"))
    }

    @Test func promptKeepsTargetAndOccurrenceWhileClippingOnlyReferences() throws {
        let context = String(repeating: "Earlier context. ", count: 800) + "Let me know when it is ready." +
            String(repeating: " Later context.", count: 800)
        let source = input(context: context)
        let prompt = try LearningExplanationPolicy.prompt(source, language: .chinese, total: 4_096, output: 1_024)
        #expect(prompt.contains("know") && prompt.contains("Let me know when it is ready."))
        #expect(prompt.utf8.count < context.utf8.count)
        #expect(ModelContextBudget.estimatedTokens(prompt) <=
            ModelContextBudget.inputAllowance(total: 4_096, output: 1_024, estimated: true))
        #expect(prompt.contains("Chinese") && prompt.contains("occurrenceQuotes"))
    }

    @Test func discontinuousAndRepeatedPartsKeepTheChosenSpans() throws {
        let text = "Keep me posted, and keep them posted too."
        let ranges = [NSRange(location: 20, length: 4), NSRange(location: 30, length: 6)]
        let source = input(target: "keep someone posted", context: text, ranges: ranges)
        let prompt = try LearningExplanationPolicy.prompt(source, language: .english, total: 4_096, output: 1_024)
        #expect(prompt.contains("keep someone posted") && prompt.contains("Keep me posted, and keep them posted too."))
        #expect(prompt.contains("\"keep\",\"posted\""))
    }

    @Test func missingEditedSpansAndOversizedTargetsCannotReachAModel() {
        #expect(!LearningExplanationPolicy.isValid(input(ranges: [])))
        #expect(throws: (any Error).self) {
            try LearningExplanationPolicy.prompt(input(ranges: []), language: .english, total: 4_096, output: 1_024)
        }
        let target = String(repeating: "word ", count: 1_000)
        #expect(throws: (any Error).self) {
            try LearningExplanationPolicy.prompt(input(target: target, context: target), language: .english, total: 2_048, output: 1_024)
        }
        #expect(!LearningExplanationPolicy.isValid(input(target: "😀", context: "😀", ranges: [NSRange(location: 1, length: 1)])))
    }

    @Test(arguments: ["Hy-MT2-1.8B-Q4_K_M.gguf", "translategemma-4b-it.gguf", "HY_MT2-7B.gguf",
                      "google/translate-gemma-4b-it", "google/hunyuan mt", "tencent/Hy.MT2"])
    func translationSpecialistsAreExcluded(_ name: String) {
        #expect(!LearningExplanationPolicy.supportsGeneralInstructions(model: name, template: .qwen3))
        #expect(!LearningExplanationPolicy.supportsGeneralInstructions(model: "renamed.gguf", template: .translateGemma))
        #expect(LearningExplanationPolicy.supportsGeneralInstructions(model: "Qwen3.5-4B-Q4_K_M.gguf", template: .qwen3))
    }

    @Test(arguments: ["gemma-4-E2B.i1-Q6_K.gguf", "gemma-4-E4B.i1-Q4_K_M.gguf", "Qwen3.5-2B-Base.i1-Q4_K_M.gguf"])
    func completionBaseWeightsAreNotExplanationModels(_ filename: String) {
        #expect(!LearningExplanationPolicy.supportsGeneralInstructions(model: filename, template: .automatic))
        #expect(LearningExplanationPolicy.supportsGeneralInstructions(model: "Gemma-4-E4B-IT.gguf", template: .gemma4))
    }

    @Test func parserAcceptsOnlyCompleteBoundedResults() throws {
        let valid = "{\"meaning\":\" 告知 \",\"explanation\":\"let someone know 表示让某人知道。\"}"
        #expect(try LearningExplanationPolicy.parse("```json\n" + valid + "\n```").meaning == "告知")
        for text in ["{\"meaning\":\"告知\"}", "unfinished", "{\"meaning\":\"\",\"explanation\":\"x\"}",
                     "{\"meaning\":\"x\",\"explanation\":\"\\u0000\"}", String(repeating: "x", count: 24_001)] {
            #expect(throws: (any Error).self) { try LearningExplanationPolicy.parse(text) }
        }
    }

    @Test(arguments: [LearningLanguage.chinese, .english, .japanese])
    func responseLanguageGovernsBothFieldsIndependentlyOfTheTarget(_ language: LearningLanguage) throws {
        let prompt = try LearningExplanationPolicy.prompt(input(), language: language, total: 8_192, output: 1_024)
        #expect(prompt.contains("\"targetLanguage\":\"en\""))
        #expect(prompt.contains("meaning AND explanation"))
        #expect(prompt.contains("Write meaning AND explanation in \(language.name)"))
    }
}
