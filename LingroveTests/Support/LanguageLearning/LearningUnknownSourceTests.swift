import Foundation
import Testing
@testable import Lingrove

/// Unknown source metadata must never become fabricated English or a pre-model failure.
struct LearningUnknownSourceTests {
    @Test func lookupOmitsUnknownSourceButKeepsTheTargetContextAndOutputLanguages() throws {
        let text = "OpenAI-compatible chat endpoint"
        let input = LearningLookupInput(target: .init(target: "compatible", dictionaryForm: "compatible",
            language: nil, kind: .word, context: text,
            ranges: [.init((text as NSString).range(of: "compatible"))], contextKind: .fragment), translationLanguage: .chinese)
        let prompt = try LearningLookupPolicy.prompt(input, language: .chinese, total: 4_096, output: 512)
        #expect(!prompt.contains("source_language"))
        #expect(!prompt.contains("from English"))
        #expect(prompt.contains(text) && prompt.contains("compatible"))
        #expect(prompt.contains(LearningLanguage.chinese.name) && prompt.contains("fragment"))
        let basic = try LearningLookupPolicy.parse(
            #"{"meaning":"兼容的","sentence_translation":"兼容 OpenAI 的聊天端点"}"#, input: input)
        let details = try LearningLookupPolicy.prompt(input, language: .chinese, total: 4_096, output: 1_024, basic: basic)
        #expect(details.contains("accepted_meaning") && details.contains("兼容的"))
        #expect(!details.contains("source_language"))
    }

    @Test(arguments: [LearningTranslationPrompt.Family.generic, .hyMT, .translateGemma])
    func everyTranslationAdapterAcceptsAnUnknownSource(_ family: LearningTranslationPrompt.Family) throws {
        let text = "OpenAI-compatible chat endpoint"
        let request = try LearningTranslationPrompt.render(source: text, sourceLanguage: nil, targetLanguage: .chinese, family: family)
        #expect(request.prompt.contains(text))
        #expect(!request.prompt.contains("English (en) to"))
        #expect(!request.prompt.contains("following English text"))
        #expect(request.prompt.contains("Chinese") || request.prompt.contains(LearningLanguage.chinese.name))
    }

    @Test func unknownSourcePreservesEnabledDictionariesWithoutAddingAutomaticNetworkRequests() {
        let configuration = LearningDictionaryConfiguration(order: [.online, .system, .bundled], enabled: [.online, .system])
        #expect(configuration.sources(for: nil) == [.online, .system])
        #expect(configuration.automaticSources(for: nil) == [.system])
        #expect(configuration.sources(for: .english) == [.online, .system])
        #expect(configuration.automaticSources(for: .english) == [.online, .system])
    }
}
