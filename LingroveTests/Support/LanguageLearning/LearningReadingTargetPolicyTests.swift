import Foundation
import Testing
@testable import Lingrove

/// These regressions keep normalization at the acquisition seam. The context contract remains
/// exact, and every accepted window must still reproduce the authoritative selected code units.
struct LearningReadingTargetPolicyTests {
    @Test(arguments: [("following", "following "), ("following", "following\r\n"), ("be\u{a0}used\nin", "be used in"),
                      ("café", "cafe\u{301}"), ("review  history", " review history\n")])
    func anchoredRepresentationsReconcileWithoutMovingRepeatedWords(_ pair: (String, String)) throws {
        let (actual, selected) = pair
        let text = "Earlier \(actual), later \(actual) remains here."
        let range = (text as NSString).range(of: actual, options: .backwards)
        let original = LearningReadingWindow(text: text, target: range, left: .container, right: .container, method: .characters)
        let aligned = try #require(LearningReadingTargetPolicy.aligned(original, expected: selected))
        #expect(aligned.target.location == range.location)
        #expect(aligned.target.length == selected.utf16.count)
        #expect((aligned.text as NSString).substring(with: aligned.target).utf16.elementsEqual(selected.utf16))
        #expect((aligned.text as NSString).substring(to: range.location).utf16.elementsEqual((text as NSString).substring(to: range.location).utf16))
        #expect((aligned.text as NSString).substring(from: NSMaxRange(aligned.target)) == " remains here.")
        let context = try #require(LearningReadingContextPolicy.resolve(aligned, expected: selected))
        #expect((context.text as NSString).substring(with: context.target) == selected.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(arguments: [("history", "History"), ("history.", "history"), ("note book", "notebook"),
                      ("supported", "support"), (" ", "\n"), ("be used in", "used in")])
    func lexicalChangesAreNotEquivalence(_ pair: (String, String)) {
        #expect(!LearningReadingTargetPolicy.equivalent(pair.0, pair.1))
    }

    @Test func invalidOrSplitGraphemeRangesAreNeverRepairedBySearching() {
        let text = "The café and cafe\u{301} are open."
        let range = (text as NSString).range(of: "cafe\u{301}", options: [.literal])
        let partial = NSRange(location: range.location, length: range.length - 1)
        for target in [partial, NSRange(location: NSNotFound, length: 4), NSRange(location: 0, length: 4)] {
            #expect(LearningReadingTargetPolicy.aligned(.init(text: text, target: target,
                left: .container, right: .container, method: .characters), expected: "café") == nil)
        }
    }

    @Test func introducedLineBreaksDoNotEraseRealParagraphBoundaries() throws {
        let text = "Keep your history safely.\nSeparate paragraph starts here."
        let selected = "history\r\n"
        let aligned = try #require(LearningReadingTargetPolicy.aligned(.init(text: text,
            target: (text as NSString).range(of: "history"), left: .container, right: .container, method: .characters), expected: selected))
        #expect(aligned.targetIntroducesLineBreaks)
        let context = try #require(LearningReadingContextPolicy.resolve(aligned, expected: selected))
        #expect(context.text.contains("safely.") && !context.text.contains("Separate"))
        #expect((context.text as NSString).substring(with: context.target) == "history")
        let existing = "history\nremains"
        let original = try #require(LearningReadingTargetPolicy.aligned(.init(text: existing,
            target: NSRange(location: 0, length: existing.utf16.count), left: .unknown, right: .unknown, method: .characters),
            expected: existing))
        #expect(!original.targetIntroducesLineBreaks)
    }

    @Test(arguments: ["AXHeading", "AXCell", "AXParagraph", "AXListItem"])
    func wholeStructuralMaterialTranslatesWithoutInventingSentenceCompleteness(_ role: String) throws {
        let title = "Hy-MT2 Translation Task Instruction Examples (Chinese-English Comparison)"
        let window = try #require(LearningReadingTargetPolicy.selectedBlock(title, expected: title, role: role))
        let context = try #require(LearningReadingContextPolicy.resolve(window, expected: title))
        #expect(context.completeness == .unknown)
        let receipt = selection(title, context: context)
        let decision = LearningReadingLookupPolicy.decision(receipt, language: .english)
        #expect(decision.capture == nil && decision.reason == .wholeBlock)
        #expect(LearningReadingTargetPolicy.selectedBlock(title, expected: "Translation Task", role: role) == nil)
    }

    @Test func inlineLabelsAndUnprovenTitlesDoNotAcquireBlockEvidence() {
        let title = "Custom Endpoint Option"
        for role in ["AXStaticText", "AXLink", "AXGroup", "AXWebArea"] {
            #expect(LearningReadingTargetPolicy.selectedBlock(title, expected: title, role: role) == nil)
        }
        #expect(LearningReadingLookupPolicy.decision(selection(title), language: .english).reason == .standaloneUnit)
    }

    @Test func inlineFragmentsDoNotInventSpacesInCJKOrInsideWords() throws {
        for (fragments, expected) in [(["中", "文"], "中文"), (["read", "ing"], "reading"),
                                      (["Custom", "Endpoint"], "Custom Endpoint")] {
            let block = try #require(LearningReadingTargetPolicy.selectedBlock(fragments, expected: expected, role: "AXHeading"))
            #expect(block.text.utf16.elementsEqual(expected.utf16))
        }
        #expect(LearningReadingTargetPolicy.selectedBlock(["Custom", "Endpoint"], expected: "Endpoint", role: "AXHeading") == nil)
    }

    @Test func unknownLanguageAndSingleWordBlocksRetainDictionaryAccess() throws {
        let word = "compatible"
        let decision = LearningReadingLookupPolicy.decision(selection(word), language: nil)
        #expect(decision.capture?.expression == word && decision.reason == .standaloneUnit)
        #expect(decision.capture?.language == nil && decision.capture?.example == nil)
        let text = "OpenAI-compatible chat endpoint"
        let window = LearningReadingWindow(text: text, target: (text as NSString).range(of: word),
            left: .layoutBlock, right: .layoutBlock, method: .block)
        let context = try #require(LearningReadingContextPolicy.resolve(window, expected: word))
        #expect(LearningReadingLookupPolicy.decision(selection(word, context: context), language: nil).reason == .contextualUnit)
    }

    private func selection(_ text: String, context: LearningReadingContext? = nil) -> LearningReadingSelection {
        .init(id: UUID(), text: text, processIdentifier: 1, bundleIdentifier: "fixture", anchor: .zero, context: context)
    }
}
