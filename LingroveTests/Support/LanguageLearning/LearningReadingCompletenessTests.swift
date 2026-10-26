import Foundation
import Testing
@testable import Lingrove

/// Regression examples from reading receipts exercise acquisition evidence, occurrence coverage
/// and the downstream model input together. No language-specific grammar guessing is involved.
struct LearningReadingCompletenessTests {
    @Test(arguments: [
        "For more experimental results and analysis, please refer to our report.",
        "Chinese names should be used in Chinese prompts, and English names should be used in English prompts.",
        "In this release, we also open-source IFMTBench, a benchmark for evaluating translation instruction-following capabilities.",
        "For on-device deployment, AngelSlim 1.25-bit extreme quantization reduces the storage requirement of the 1.8B model to only 440 MB and improves inference speed by 1.5x."
    ])
    func entireMaterialTranslatesDespiteUnverifiedNodeEdges(_ sentence: String) throws {
        for target in [sentence, String(sentence.dropLast()), " " + sentence + " "] {
            let text = target.hasPrefix(" ") ? target : sentence
            let context = try make(text, target: target)
            #expect(context.completeness == .unknown && context.selectionCoversContext)
            #expect(LearningReadingLookupPolicy.capture(selection(target, context), language: .english) == nil)
        }
    }

    @Test func aWordKeepsUnknownEvidenceThroughSavingAndBothPrompts() throws {
        let sentence = "For more experimental results and analysis, please refer to our report."
        let context = try make(sentence, target: "report")
        let capture = try #require(LearningReadingLookupPolicy.capture(selection("report", context), language: .english))
        #expect(capture.kind == .word && capture.example?.completeness == .unknown)
        let input = LearningExplanationPolicy.input(capture)
        #expect(input.contextKind == .unknown)
        let basic = try LearningLookupPolicy.prompt(.init(target: input, translationLanguage: .chinese),
            language: .chinese, total: 8192, output: 1024)
        #expect(basic.contains("\"context_completeness\":\"unknown\""))
        #expect(!basic.contains("Only a fragment is available"))
        let detail = try LearningExplanationPolicy.prompt(input, language: .chinese, total: 8192, output: 1024)
        #expect(detail.contains("boundaries are unverified") && !detail.contains("Only a context fragment"))
        #expect(try JSONDecoder().decode(LearningExplanationInput.self, from: JSONEncoder().encode(input)) == input)
    }

    @Test func knownCropsAndLocalClausesRemainLookups() throws {
        let tail = "while preserving your review history."
        let cropped = try make(tail, target: tail, left: .crop, right: .unknown)
        #expect(cropped.completeness == .fragment)
        #expect(LearningReadingLookupPolicy.capture(selection(tail, cropped), language: .english)?.kind == .expression)
        let full = "Send notes to Anki while preserving your review history."
        let partial = try make(full, target: tail, left: .container, right: .container)
        #expect(!partial.selectionCoversContext)
        #expect(LearningReadingLookupPolicy.capture(selection(tail, partial), language: .english)?.kind == .expression)
        let word = try make("The report is ready.", target: "report")
        #expect(LearningReadingLookupPolicy.capture(selection("report", word), language: .english)?.kind == .word)
    }

    @Test func omittedDecorationsDoNotHideOmittedWordsOrMoveAnOccurrence() throws {
        for (text, target) in [("The report is ready.”", "The report is ready"),
                               ("报告已经完成。", "报告已经完成"), ("Ready?", "Ready")] {
            #expect(try make(text, target: target).selectionCoversContext)
        }
        let quoted = "The report is ready.”  "
        let quotedContext = try make(quoted, target: "The report is ready")
        #expect(LearningReadingLookupPolicy.capture(selection("The report is ready", quotedContext), language: .english) == nil)
        let uncertainWord = try make("Ready?", target: "Ready")
        #expect(LearningReadingLookupPolicy.capture(selection("Ready", uncertainWord), language: .english)?.kind == .word)
        let chinese = try make("报告已经完成。", target: "报告已经完成")
        #expect(LearningReadingLookupPolicy.capture(selection("报告已经完成", chinese), language: .chinese) == nil)
        for (text, target) in [("The report is ready.", "report is ready"),
                               ("The report is ready, if needed.", "The report is ready"),
                               ("The report is ready. Another sentence.", "The report is ready") ] {
            // Only the containing sentence is in scope, so an independent following sentence is
            // allowed; lexical omissions inside the containing sentence are not decorations.
            let context = try make(text, target: target)
            #expect(context.selectionCoversContext == text.contains("Another sentence"))
            #expect((context.window.text as NSString).substring(with: context.window.target) == target)
        }
        let repeated = "The report is ready. The report is ready."
        let range = (repeated as NSString).range(of: "The report is ready", options: .backwards)
        let context = try #require(LearningReadingContextPolicy.resolve(.init(text: repeated, target: range,
            left: .unknown, right: .unknown, method: .block), expected: "The report is ready"))
        #expect(context.selectionCoversContext && context.window.target == range)
    }

    @Test func unknownDoesNotUpgradeAcquisitionAndLegacyValuesStillDecode() throws {
        for value in [VocabularyExample.Completeness.sentence, .fragment, .unknown] {
            #expect(try JSONDecoder().decode(VocabularyExample.Completeness.self,
                from: Data("\"\(value.rawValue)\"".utf8)) == value)
        }
        let complete = try make("An entire sentence.", target: "entire", left: .container, right: .container)
        #expect(complete.completeness == .sentence)
        let unknown = try make("An entire sentence.", target: "entire")
        #expect(unknown.completeness == .unknown && !unknown.isComplete)
        let clipped = try make("An entire sentence.", target: "entire", left: .crop, right: .sentence)
        #expect(clipped.completeness == .fragment)
    }

    private func make(_ text: String, target: String, left: LearningReadingWindow.Boundary = .unknown,
                      right: LearningReadingWindow.Boundary = .unknown) throws -> LearningReadingContext {
        try #require(LearningReadingContextPolicy.resolve(.init(text: text, target: (text as NSString).range(of: target),
            left: left, right: right, method: .block), expected: target))
    }
    private func selection(_ text: String, _ context: LearningReadingContext) -> LearningReadingSelection {
        .init(id: UUID(), text: text, processIdentifier: 1, bundleIdentifier: "fixture", anchor: .zero, context: context)
    }
}
