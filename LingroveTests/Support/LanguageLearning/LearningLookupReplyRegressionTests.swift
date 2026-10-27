import Foundation
import Testing

@testable import Lingrove

/// Guards the small-model lookup contract at the prompt/parser boundary. These tests use fixed
/// model replies so a prompt regression or a placeholder acceptance cannot silently become a
/// cached meaning; they do not load a model or access a host application.
struct LearningLookupReplyRegressionTests {
    @Test
    func firstStageOmitsUnacceptedAndUnavailableReferenceFields() throws {
        let input = makeInput(context: .sentence)

        let prompt = try LearningLookupPolicy.prompt(
            input, language: .chinese, total: 4_096, output: 512)

        #expect(!prompt.contains("accepted_meaning"))
        #expect(!prompt.contains("accepted_sentence_translation"))
        #expect(!prompt.contains("\"reference_translation\""))
        #expect(prompt.contains("sentence_translation"))

        let withReference = makeInput(context: .sentence, referenceTranslation: "我们今天支持这个方案。")
        let referencedPrompt = try LearningLookupPolicy.prompt(
            withReference, language: .chinese, total: 4_096, output: 512)
        #expect(referencedPrompt.contains("\"reference_translation\""))
        #expect(referencedPrompt.contains("我们今天支持这个方案。"))
    }

    @Test
    func noContextUsesGeneralMeaningTaskAndKeepsTranslationEmpty() throws {
        let input = makeInput(context: .none, target: "bank")

        let prompt = try LearningLookupPolicy.prompt(
            input, language: .chinese, total: 4_096, output: 512)

        #expect(prompt.contains("This is a standalone dictionary query."))
        #expect(prompt.contains(
            "Define the target word or expression from \(LearningLanguage.english.name) in \(LearningLanguage.chinese.name)"))
        #expect(prompt.contains("common senses"))
        #expect(prompt.contains(#""sentence_translation":"""#))
        #expect(prompt.contains("\"target\":\"bank\""))
        #expect(!prompt.contains("\"context\""))
        #expect(!prompt.contains("\"context_completeness\""))
        #expect(!prompt.contains("\"occurrence_quotes\""))
        #expect(!prompt.contains("\"occurrence_ranges\""))
        #expect(!prompt.contains("accepted_meaning"))
        #expect(!prompt.contains("accepted_sentence_translation"))
        #expect(!prompt.contains("\"reference_translation\""))

        let result = try LearningLookupPolicy.parse(
            #"{"meaning":"银行；河岸","sentence_translation":""}"#,
            input: input)
        #expect(result.meaning == "银行；河岸")
        #expect(result.sentenceTranslation.isEmpty)
        #expect(throws: (any Error).self) {
            try LearningLookupPolicy.parse(
                #"{"meaning":"银行；河岸","sentence_translation":"他坐在银行旁。"}"#,
                input: input)
        }
    }

    @Test(arguments: [
        "未提供", "未提供释义", "未提供含义", "暂无释义", "暂无解释", "未指定", "无法确定", "未知",
        "Not Provided.", "Meaning not provided", "Definition not provided", "Unavailable", "N/A", "Null", "Unknown"
    ])
    func rejectsAPlaceholderMeaning(_ meaning: String) throws {
        let input = makeInput(context: .none)
        let reply = try basicReply(meaning: meaning, sentenceTranslation: "")

        #expect(throws: (any Error).self) {
            try LearningLookupPolicy.parse(reply, input: input)
        }
    }

    @Test
    func aDefinitionMayMentionTheWordsNotProvidedWithoutBeingAPlaceholder() throws {
        let input = makeInput(context: .none)
        let reply = try basicReply(
            meaning: "The phrase ‘not provided’ means the information was omitted.",
            sentenceTranslation: "")

        let parsed = try LearningLookupPolicy.parse(reply, input: input)
        #expect(parsed.meaning == "The phrase ‘not provided’ means the information was omitted.")
        #expect(parsed.sentenceTranslation.isEmpty)
    }

    @Test
    func contextualPairCanAnchorDetailsWithoutReplacingTheAcceptedInterpretation() throws {
        let input = makeInput(context: .sentence)
        let basic = try LearningLookupPolicy.parse(
            #"{"meaning":"支持","sentence_translation":"我们今天支持这个方案。"}"#,
            input: input)
        let detailsPrompt = try LearningLookupPolicy.prompt(
            input, language: .chinese, total: 4_096, output: 1_024, basic: basic)

        #expect(detailsPrompt.contains("\"accepted_meaning\":\"支持\""))
        #expect(detailsPrompt.contains("\"accepted_sentence_translation\":\"我们今天支持这个方案。\""))
        #expect(detailsPrompt.contains("original target") && detailsPrompt.contains("plain text, without JSON"))
        #expect(try LearningLookupPolicy.parseDetails("support 在这里表示赞成。")
            == "support 在这里表示赞成。")
    }

    @Test
    func detailsPreserveQuotedWordsAndParagraphsWithoutModelAuthoredJSONEscaping() throws {
        let prose = "在原句中，\"Hello\" 是问候语。\n\n引号、路径 C:\\notes 和 😀 都是正文。"
        #expect(try LearningLookupPolicy.parseDetails(" \n" + prose + "\n ") == prose)
    }

    @Test
    func detailsReceiveOneAcceptedTranslationAndDoNotRereadTheEarlierReference() throws {
        let input = makeInput(context: .sentence, referenceTranslation: "过期的参考译文")
        let basic = LearningLookupResult(meaning: "支持", sentenceTranslation: "已选定的译文")
        let prompt = try LearningLookupPolicy.prompt(input, language: .chinese, total: 4_096, output: 1_024, basic: basic)
        #expect(prompt.contains("已选定的译文"))
        #expect(!prompt.contains("过期的参考译文") && !prompt.contains("reference_translation"))
    }

    @Test
    func matchingMeaningAndTranslationRemainValidWithoutSemanticAcceptanceRules() throws {
        let input = makeInput(context: .sentence)
        let reply = try basicReply(meaning: "支持", sentenceTranslation: "支持")
        #expect(try LearningLookupPolicy.parse(reply, input: input).meaning == "支持")
    }

    private func makeInput(context: LearningExplanationContext, target: String = "support",
                           referenceTranslation: String = "") -> LearningLookupInput {
        let text = context == .none ? target : "We support this plan today."
        let range = (text as NSString).range(of: target)
        return .init(
            target: .init(target: target, dictionaryForm: target, language: .english, kind: .word,
                          context: text, ranges: [.init(range)], contextKind: context),
            translationLanguage: .chinese,
            referenceTranslation: referenceTranslation)
    }

    private func basicReply(meaning: String, sentenceTranslation: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "meaning": meaning,
            "sentence_translation": sentenceTranslation
        ], options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }
}
