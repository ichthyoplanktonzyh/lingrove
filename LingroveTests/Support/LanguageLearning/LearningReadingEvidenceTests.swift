import Foundation
import Testing

@testable import Lingrove

/// These cases assert the reading contract, before any prompt or model can hide acquisition errors.
@Suite
struct LearningReadingEvidenceTests {
    private let sentence = "Preview recognition and cloze/gap cards, attach generated TTS audio, and send or batch-update notes directly to Anki Desktop via AnkiConnect while preserving your review history."

    @Test func linkedTailCannotClaimACompleteSentence() throws {
        let tail = " while preserving your review history."
        let candidate = window(tail, target: "history", method: .sentence)
        let context = try #require(LearningReadingContextPolicy.resolve(candidate, expected: "history"))
        #expect(!context.isComplete)
        #expect(context.left == .unknown)
        #expect(context.example(app: "fixture").completeness == .unknown)
    }

    @Test func completeBlockWinsRegardlessOfCandidateOrder() throws {
        let tail = window(" while preserving your review history.", target: "history", method: .sentence)
        let block = window(sentence, target: "history", left: .container, right: .container, method: .block)
        for candidates in [[tail, block], [block, tail]] {
            let result = try #require(LearningReadingContextPolicy.best(candidates, expected: "history"))
            #expect(result.text == sentence)
            #expect(result.isComplete)
            #expect((result.text as NSString).substring(with: result.target) == "history")
        }
    }

    @Test func surroundingSentenceBoundariesAreIndependentOfNodeLabels() throws {
        let text = "Earlier material. The second bank is open. Later material."
        let result = try #require(LearningReadingContextPolicy.resolve(window(text, target: "bank"), expected: "bank"))
        #expect(result.isComplete)
        #expect(result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "The second bank is open.")
        #expect(result.left == .sentence && result.right == .sentence)
    }

    @Test func wholeMultipleSentencesTranslateInsteadOfBecomingAnExpression() throws {
        let text = "The app translates text. It also offers speech."
        let context = try #require(LearningReadingContextPolicy.resolve(
            window(text, target: text, left: .container, right: .container), expected: text))
        #expect(context.isComplete && context.sentenceCount == 2 && context.selectionCoversContext)
        let receipt = LearningReadingSelection(id: UUID(), text: text, processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: .zero, context: context)
        #expect(LearningReadingLookupPolicy.capture(receipt, language: .english) == nil)
    }

    @Test func selectedTailRemainsLookupDespiteFinalPeriod() throws {
        let text = "while preserving your review history."
        let context = try #require(LearningReadingContextPolicy.resolve(window(text, target: text, left: .crop, right: .sentence, method: .ocr), expected: text))
        let receipt = LearningReadingSelection(id: UUID(), text: text, processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: .zero, context: context)
        #expect(LearningReadingLookupPolicy.capture(receipt, language: .english)?.kind == .expression)
    }

    @Test func finiteBudgetCanMoveToTheNeededSide() throws {
        let target = NSRange(location: 900, length: 7)
        let range = try #require(LearningReadingContextPolicy.windowRange(target: target, count: 908))
        #expect(range.location == 0 && range.length == 908)
        let long = String(repeating: "Earlier ", count: 80) + "words support history."
        let context = try #require(LearningReadingContextPolicy.resolve(
            window(long, target: "history", left: .container, right: .container), expected: "history"))
        #expect(context.text == long && context.isComplete)
    }

    @Test func whitespaceCannotProveTheStartOfACroppedSentence() throws {
        for text in [" while preserving history.", "\n\nwhile preserving history."] {
            let context = try #require(LearningReadingContextPolicy.resolve(window(text, target: "history"), expected: "history"))
            #expect(context.left == .unknown && !context.isComplete)
        }
    }

    @Test func exampleConversionKeepsOneStableCaptureIdentity() throws {
        let context = try #require(LearningReadingContextPolicy.resolve(
            window(sentence, target: "history", left: .container, right: .container), expected: "history"))
        let receipt = LearningReadingSelection(id: UUID(), text: "history", processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: .zero, context: context)
        #expect(receipt.vocabularyContext?.id == receipt.id)
        #expect(receipt.vocabularyContext == receipt.vocabularyContext)
    }

    @Test func artificialEdgeDoesNotPromoteAnAbbreviationToACompleteSentence() throws {
        let text = "Please ask Dr."
        let result = try #require(LearningReadingContextPolicy.resolve(
            window(text, target: "ask", left: .container, right: .crop), expected: "ask"))
        #expect(!result.isComplete)
    }

    @Test func artificialUnicodeEdgesAreDiscardedWithoutMovingTheOccurrence() throws {
        let text = "\u{301} prefix target suffix 👩🏽‍💻"
        let result = try #require(LearningReadingContextPolicy.resolve(
            window(text, target: "target", left: .crop, right: .crop), expected: "target"))
        #expect(!result.window.text.contains("\u{301}"))
        #expect(!result.window.text.contains("👩🏽‍💻"))
        #expect((result.text as NSString).substring(with: result.target) == "target")
    }

    @Test func inlineGroupsAndClippedOffscreenFramesAreNotBlocks() {
        let frame = CGRect(x: 20, y: 100, width: 200, height: 20)
        #expect(!LearningReadingBlockPolicy.separates(frame,
            before: CGRect(x: 0, y: 100, width: 20, height: 20),
            after: CGRect(x: 220, y: 100, width: 50, height: 20), first: false, last: false))
        #expect(LearningReadingBlockPolicy.separates(frame,
            before: CGRect(x: 20, y: 50, width: 200, height: 20),
            after: CGRect(x: 20, y: 150, width: 200, height: 20), first: false, last: false))
        #expect(!LearningReadingBlockPolicy.separates(CGRect(x: 20, y: 100, width: 200, height: 1),
            before: nil, after: nil, first: true, last: true))
    }

    @Test func layoutOnlyRangesNeverCertifyWrappedInlinePhrases() throws {
        let phrase = "several styled lines that remain"
        let full = "We keep this entire sentence on several styled lines that remain part of a single thought."
        let narrow = window(phrase, target: "styled", left: .layoutBlock, right: .layoutBlock, method: .block)
        let wide = window(full, target: "styled", left: .layoutBlock, right: .layoutBlock, method: .block)
        #expect(LearningReadingContextPolicy.resolve(narrow, expected: "styled")?.isComplete == false)
        let best = try #require(LearningReadingContextPolicy.best([narrow, wide], expected: "styled"))
        #expect(best.text == full && !best.isComplete)
        #expect(best.example(app: "fixture").completeness == .unknown)
    }

    @Test func selectingTheWholeLayoutBlockCanTranslateWithoutClaimingSentenceCertainty() throws {
        let text = "The app translates text. It also offers speech."
        let context = try #require(LearningReadingContextPolicy.resolve(
            window(text, target: text, left: .layoutBlock, right: .layoutBlock, method: .block), expected: text))
        #expect(!context.isComplete)
        let receipt = LearningReadingSelection(id: UUID(), text: text, processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: .zero, context: context)
        #expect(LearningReadingLookupPolicy.capture(receipt, language: .english) == nil)
    }

    private func window(_ text: String, target: String, left: LearningReadingWindow.Boundary = .unknown,
                        right: LearningReadingWindow.Boundary = .unknown,
                        method: LearningReadingWindow.Method = .characters) -> LearningReadingWindow {
        .init(text: text, target: (text as NSString).range(of: target), left: left, right: right, method: method)
    }
}
