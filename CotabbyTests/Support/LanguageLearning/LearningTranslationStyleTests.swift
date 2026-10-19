import Foundation
import Testing
@testable import Cotabby

struct LearningTranslationStyleTests {
    @Test(arguments: [LearningTranslationPrompt.Family.generic, .hyMT])
    func styleKeepsTargetSeparateAndIsIncludedInTheBudget(_ family: LearningTranslationPrompt.Family) throws {
        let style = LearningTranslationStyle(register: .custom, customInstruction: "Use concise everyday language. \"quoted\"")
        let source = "今天没有发送2个文件。"
        let input = LearningTranslationInput(source: source, referenceBefore: String(repeating: "unrelated draft ", count: 500), style: style)
        let bare = try LearningTranslationPrompt.render(source: source, sourceLanguage: .chinese,
            targetLanguage: .english, family: family, style: style)
        #expect(bare.prompt.contains(source) && bare.prompt.contains("Translation style preference (JSON):"))
        let budget = bare.prompt.count + 32 + 100
        let plan = try LearningTranslationBudget.prompt(input: input, sourceLanguage: .chinese,
            targetLanguage: .english, family: family, total: budget, output: 100, estimated: false) { $0.count }
        #expect(plan.prompt == bare.prompt)
        #expect(throws: (any Error).self) {
            try LearningTranslationBudget.prompt(input: input, sourceLanguage: .chinese,
                targetLanguage: .english, family: family, total: budget - 1, output: 100, estimated: false) { $0.count }
        }
    }
    @Test func unsupportedSpecialistStyleCannotSilentlyEnterThePrompt() {
        #expect(throws: (any Error).self) {
            try LearningTranslationPrompt.render(source: "你好", sourceLanguage: .chinese,
                targetLanguage: .english, family: .translateGemma, style: .init(register: .formal))
        }
    }

    @Test func customInstructionsAreBoundedWithoutChangingSource() {
        let style = LearningTranslationStyle(register: .custom, customInstruction: String(repeating: "你好", count: 5000))
        #expect(style.normalized.customInstruction.count <= 1000)
        #expect(style.normalized.customInstruction.utf8.count <= 4000)
        #expect(LearningTranslationStyle().instruction == nil)
    }
}
