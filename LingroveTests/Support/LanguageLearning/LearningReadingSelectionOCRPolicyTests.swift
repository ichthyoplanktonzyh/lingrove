import Foundation
import CoreGraphics
import NaturalLanguage
import Testing
@testable import Lingrove

/// Synthetic OCR retains exact source offsets and positions, allowing ambiguous repeated terms
/// and canonical-equivalent strings to be checked independently of Vision's current recognition.
struct LearningReadingSelectionOCRPolicyTests {
    private let region = CGRect(x: -1000, y: 900, width: 1000, height: 600)
    private let pixels = CGSize(width: 2000, height: 1200)

    @Test func exactWordGetsWiderContextWithoutChangingTheAXTarget() throws {
        let extraction = fixture(["Earlier sentence. He sat on the bank of the river. Another sentence."])
        let selection = try selected("bank", from: extraction)
        let match = try #require(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels))
        #expect(match.context.text.trimmingCharacters(in: .whitespacesAndNewlines) == "He sat on the bank of the river.")
        #expect(match.context.isComplete && match.context.window.method == .selectionOCR)
        #expect((match.context.window.text as NSString).substring(with: match.context.window.target).utf16.elementsEqual(selection.text.utf16))
    }

    @Test func repeatedWordUsesItsGeometryAndAnOverlappingAmbiguityIsRejected() throws {
        let extraction = fixture(["Earlier sentence. A bank financed another bank by the river. Next sentence."])
        let selection = try selected("bank", from: extraction, last: true)
        let context = try #require(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels)?.context)
        #expect(context.target == (context.text as NSString).range(of: "bank", options: .backwards))
        let bankWords = extraction.words.filter { $0.text == "bank" }
        let lastBox = try #require(bankWords.last?.boundingBox)
        let words = extraction.words.map { word in
            word.text == "bank" ? ScreenTextWord(text: word.text, boundingBox: lastBox, lineIndex: word.lineIndex,
                utf16Location: word.utf16Location, utf16Length: word.utf16Length, confidence: 1) : word
        }
        let ambiguous = ExtractedScreenText(text: extraction.text, lineCount: 1, lines: extraction.lines, words: words)
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: ambiguous, region: region, pixels: pixels) == nil)
    }

    @Test func missingBoundsAndAnotherOccurrenceNeverUseTheMouseAnchorAsEvidence() throws {
        let extraction = fixture(["Earlier sentence. Keep your history safe. Next sentence."])
        var selection = try selected("history", from: extraction)
        selection.selectionBounds = nil
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) == nil)
        selection.selectionBounds = CGRect(x: region.minX + 850, y: region.minY + 100, width: 80, height: 24)
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) == nil)
    }

    @Test(arguments: ["bank", "b4nk"])
    func horizontalFragmentsRetainTheSecondRepeatedWordsSourceOffset(_ recognized: String) throws {
        let raw = fixture(["Earlier sentence. A bank", "financed another \(recognized) by the river. Next sentence."])
        let boxes = [CGRect(x: 0.1, y: 0.55, width: 0.35, height: 0.04),
                     CGRect(x: 0.46, y: 0.55, width: 0.44, height: 0.04)]
        let lines = raw.lines.enumerated().map { index, line in
            OCRTextHygiene.OCRLine(text: line.text, confidence: 1, boundingBox: boxes[index])
        }
        let words = raw.words.map { word -> ScreenTextWord in
            let index = word.lineIndex ?? 0, offset = word.utf16Location ?? 0, length = word.utf16Length ?? 0
            let box = boxes[index], count = CGFloat(lines[index].text.utf16.count)
            return .init(text: word.text, boundingBox: CGRect(x: box.minX + box.width * CGFloat(offset) / count,
                y: box.minY, width: box.width * CGFloat(length) / count, height: box.height), lineIndex: index,
                utf16Location: offset, utf16Length: length, confidence: 1)
        }
        let extraction = ExtractedScreenText(text: raw.text, lineCount: 2, lines: lines, words: words)
        let hit = try selected(recognized, from: extraction, last: true)
        let quote = "another bank by the river."
        let selection = LearningReadingSelection(id: UUID(), text: "bank", processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: hit.anchor,
            context: LearningReadingContextPolicy.resolve(.init(text: quote, target: (quote as NSString).range(of: "bank"),
                left: .crop, right: .crop, method: .markerWindow), expected: "bank"), selectionBounds: hit.selectionBounds)
        let context = try #require(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels)?.context)
        #expect(context.text.contains("A bank financed another bank by the river."))
        #expect(context.target == (context.text as NSString).range(of: "bank", options: .backwards))
    }

    @Test func aCoarseAXTextRunNeedsExactNeighbourEvidenceAndCannotUseAPageFrame() throws {
        let extraction = fixture(["Earlier sentence. Keep your review history safely. Next sentence."])
        var selection = try selected("history", from: extraction)
        let word = try #require(selection.selectionBounds)
        selection.selectionBounds = CGRect(x: region.minX + 100, y: word.minY, width: 800, height: word.height)
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) == nil)
        let fragment = "your review history safely."
        selection.context = LearningReadingContextPolicy.resolve(.init(text: fragment,
            target: (fragment as NSString).range(of: "history"), left: .crop, right: .crop, method: .markerWindow), expected: "history")
        let matched = try #require(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels))
        #expect(matched.context.text.contains("Keep your review history safely."))
        let run = try #require(selection.selectionBounds)
        selection.selectionBounds = run.offsetBy(dx: 0, dy: 3.1)
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) != nil,
            "The same highlighted word can have a slightly different vertical envelope in a wider Vision crop")
        selection.selectionBounds = run.offsetBy(dx: 0, dy: 30)
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) == nil)
        selection.selectionBounds = run
        let distant = "unrelated" + String(repeating: " ", count: 40) + "history safely."
        selection.context = LearningReadingContextPolicy.resolve(.init(text: distant,
            target: (distant as NSString).range(of: "history"), left: .crop, right: .crop, method: .markerWindow), expected: "history")
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) == nil,
            "Uncompared text outside the adjacent quote cannot corroborate a coarse box")
        selection.context = matched.context
        selection.selectionBounds = region
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) == nil)
    }

    @Test func softWrapAndCanonicalEquivalencePreserveEverySelectedUTF16Unit() throws {
        let extraction = fixture(["Earlier sentence. We preserve your review", "history safely. Another sentence."])
        let your = try #require(extraction.words.first { $0.text == "your" })
        let history = try #require(extraction.words.first { $0.text == "history" })
        let box = LearningReadingVisualPolicy.screenRect(your.boundingBox.union(history.boundingBox), in: region)
        let text = "your review\nhistory"
        let selection = LearningReadingSelection(id: UUID(), text: text, processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: box, selectionBounds: box)
        let context = try #require(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels)?.context)
        #expect((context.window.text as NSString).substring(with: context.window.target).utf16.elementsEqual(text.utf16))
        #expect(context.text.contains("We preserve your review\nhistory safely."))

        let accents = fixture(["Earlier sentence. Visit the café today. Next sentence."])
        var accentSelection = try selected("café", from: accents)
        accentSelection = .init(id: accentSelection.id, text: "cafe\u{301}", processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: accentSelection.anchor, selectionBounds: accentSelection.selectionBounds)
        let accent = try #require(LearningReadingSelectionOCRPolicy.match(accentSelection, extraction: accents, region: region, pixels: pixels)?.context)
        #expect((accent.window.text as NSString).substring(with: accent.window.target).utf16.elementsEqual("cafe\u{301}".utf16))
    }

    @Test func highlightedOCRSpellingCanUseAPreciseWordBoxAndExactAXNeighbours() throws {
        let extraction = fixture(["Earlier sentence. Keep your review hivory safely. Next sentence."])
        let mistaken = try selected("hivory", from: extraction)
        let quote = "your review history safely."
        var selection = LearningReadingSelection(id: UUID(), text: "history", processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: mistaken.anchor, selectionBounds: mistaken.selectionBounds)
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) == nil)
        selection.context = LearningReadingContextPolicy.resolve(.init(text: quote,
            target: (quote as NSString).range(of: "history"), left: .crop, right: .crop, method: .markerWindow), expected: "history")
        let context = try #require(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels)?.context)
        #expect(context.text.contains("Keep your review history safely."))
        #expect((context.window.text as NSString).substring(with: context.window.target) == "history")
        let precise = try #require(selection.selectionBounds)
        selection.selectionBounds = CGRect(x: region.minX + 100, y: precise.minY, width: 800, height: precise.height)
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) == nil,
            "Misspelled OCR cannot be recovered from a coarse run rectangle")
        selection.selectionBounds = precise
        let conflict = "the search history today."
        selection.context = LearningReadingContextPolicy.resolve(.init(text: conflict,
            target: (conflict as NSString).range(of: "history"), left: .crop, right: .crop, method: .markerWindow), expected: "history")
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) == nil)
    }

    @Test func quotedMisspelledWordsStillRejectAmbiguousOverlappingOccurrences() throws {
        let raw = fixture(["Keep your review hivory safely. Keep your review hivory safely."])
        let sameBox = try #require(raw.words.first { $0.text == "hivory" }?.boundingBox)
        let words = raw.words.map { word in
            word.text == "hivory" ? ScreenTextWord(text: word.text, boundingBox: sameBox, lineIndex: word.lineIndex,
                utf16Location: word.utf16Location, utf16Length: word.utf16Length, confidence: 1) : word
        }
        let extraction = ExtractedScreenText(text: raw.text, lineCount: 1, lines: raw.lines, words: words)
        let quote = "your review history safely."
        let bounds = LearningReadingVisualPolicy.screenRect(sameBox, in: region)
        let selection = LearningReadingSelection(id: UUID(), text: "history", processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: bounds,
            context: LearningReadingContextPolicy.resolve(.init(text: quote, target: (quote as NSString).range(of: "history"),
                left: .crop, right: .crop, method: .markerWindow), expected: "history"), selectionBounds: bounds)
        if case .ambiguous = LearningReadingSelectionOCRPolicy.alignment(selection, extraction: extraction, region: region, pixels: pixels) {} else {
            Issue.record("Two matching quotes and overlapping glyph boxes cannot establish a unique occurrence")
        }
    }

    @Test func spellingRecoveryCannotConsumePunctuationOutsideTheAXWord() throws {
        let raw = fixture(["Keep your review hivory. Next sentence."])
        let words = raw.words.map { word in
            word.text == "hivory" ? ScreenTextWord(text: "hivory.", boundingBox: word.boundingBox, lineIndex: word.lineIndex,
                utf16Location: word.utf16Location, utf16Length: (word.utf16Length ?? 0) + 1, confidence: 1) : word
        }
        let extraction = ExtractedScreenText(text: raw.text, lineCount: 1, lines: raw.lines, words: words)
        let bounds = try selected("hivory", from: raw).anchor
        // This AX node ends at the selection, so it supplies no right-side punctuation proof.
        let quote = "your review history"
        let selection = LearningReadingSelection(id: UUID(), text: "history", processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: bounds,
            context: LearningReadingContextPolicy.resolve(.init(text: quote, target: (quote as NSString).range(of: "history"),
                left: .crop, right: .crop, method: .markerWindow), expected: "history"), selectionBounds: bounds)
        #expect(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels) == nil)
    }

    @Test func sharedCompoundBoxCanAlignAnExplicitSubwordWithoutGuessing() throws {
        let extraction = fixture(["OpenAl-compatible chat endpoint"])
        let box = CGRect(x: 0.1, y: 0.55, width: 0.4, height: 0.04)
        let words = extraction.words.map { word in
            ["OpenAl", "compatible"].contains(word.text) ? ScreenTextWord(text: word.text, boundingBox: box,
                lineIndex: word.lineIndex, utf16Location: word.utf16Location, utf16Length: word.utf16Length, confidence: 1) : word
        }
        let data = ExtractedScreenText(text: extraction.text, lineCount: 1, lines: extraction.lines, words: words)
        let selectedBox = LearningReadingVisualPolicy.screenRect(CGRect(x: 0.26, y: 0.55, width: 0.24, height: 0.04), in: region)
        let selection = LearningReadingSelection(id: UUID(), text: "compatible", processIdentifier: 1,
            bundleIdentifier: "fixture", anchor: selectedBox, selectionBounds: selectedBox)
        let context = try #require(LearningReadingSelectionOCRPolicy.match(selection, extraction: data, region: region, pixels: pixels)?.context)
        #expect((context.text as NSString).substring(with: context.target) == "compatible")
        #expect(context.text.contains("OpenAl-compatible"), "OCR characters outside the exact AX selection are not silently repaired")
    }

    @Test func completeOrContradictingAXContextIsNotOverwritten() throws {
        let extraction = fixture(["Earlier sentence. He sat on the bank of the river. Next sentence."])
        let selection = try selected("bank", from: extraction)
        let visual = try #require(LearningReadingSelectionOCRPolicy.match(selection, extraction: extraction, region: region, pixels: pixels)?.context)
        func context(_ text: String, complete: Bool) throws -> LearningReadingContext {
            try #require(LearningReadingContextPolicy.resolve(.init(text: text, target: (text as NSString).range(of: "bank"),
                left: complete ? .container : .crop, right: complete ? .container : .crop, method: .characters), expected: "bank"))
        }
        let exact = try context("He sat on the bank of the river.", complete: true)
        #expect(LearningReadingSelectionOCRPolicy.preferred(ax: exact, visual: visual, expected: "bank") == exact)
        let conflicting = try context("the bank approved a loan", complete: false)
        #expect(LearningReadingSelectionOCRPolicy.preferred(ax: conflicting, visual: visual, expected: "bank") == conflicting)
        let partial = try context("the bank of the river.", complete: false)
        #expect(LearningReadingSelectionOCRPolicy.preferred(ax: partial, visual: visual, expected: "bank") == visual)
    }

    private func selected(_ text: String, from extraction: ExtractedScreenText, last: Bool = false) throws -> LearningReadingSelection {
        let words = extraction.words.filter { $0.text == text }
        let word = try #require(last ? words.last : words.first)
        let bounds = LearningReadingVisualPolicy.screenRect(word.boundingBox, in: region)
        return .init(id: UUID(), text: text, processIdentifier: 1, bundleIdentifier: "fixture", anchor: bounds, selectionBounds: bounds)
    }

    private func fixture(_ texts: [String]) -> ExtractedScreenText {
        var lines: [OCRTextHygiene.OCRLine] = [], words: [ScreenTextWord] = []
        for (index, text) in texts.enumerated() {
            let y = 0.55 - CGFloat(index) * 0.06
            lines.append(.init(text: text, confidence: 1, boundingBox: CGRect(x: 0.1, y: y, width: 0.8, height: 0.04)))
            let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let offset = NSRange(range, in: text)
                words.append(.init(text: String(text[range]),
                    boundingBox: CGRect(x: 0.1 + 0.8 * CGFloat(offset.location) / CGFloat(text.utf16.count), y: y,
                        width: 0.8 * CGFloat(offset.length) / CGFloat(text.utf16.count), height: 0.04), lineIndex: index,
                    utf16Location: offset.location, utf16Length: offset.length, confidence: 1))
                return true
            }
        }
        return .init(text: texts.joined(separator: "\n"), lineCount: lines.count, lines: lines, words: words)
    }
}
