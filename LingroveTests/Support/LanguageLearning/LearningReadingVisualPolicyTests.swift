import CoreGraphics
import Foundation
import Testing
@testable import Lingrove

struct LearningReadingVisualPolicyTests {
    @Test func snapshotStaysOnThePointedDisplayAndInsideTheVisibleWindow() throws {
        let screen = CGRect(x: -1600, y: 900, width: 1600, height: 1000)
        let window = CGRect(x: -1700, y: 1000, width: 1100, height: 1100)
        let point = CGPoint(x: -1595, y: 1895)
        for scale: CGFloat in [1, 2, 3, 4] {
            let bounds = try #require(LearningReadingVisualPolicy.snapshotBounds(at: point, screen: screen, window: window, scale: scale))
            #expect(screen.contains(bounds) && window.contains(bounds) && bounds.contains(point))
            #expect(bounds.width * bounds.height * scale * scale <= 16_000_001)
        }
        #expect(LearningReadingVisualPolicy.snapshotBounds(at: .zero, screen: screen, window: window, scale: 2) == nil)
        #expect(LearningReadingVisualPolicy.snapshotBounds(at: point, screen: screen, window: nil, scale: 2) == nil)
    }

    @Test func cropRoundTripRetainsNegativeOriginsAndRetinaPixelEdges() {
        let frame = CGRect(x: -1200, y: 1000, width: 1000, height: 600)
        let region = CGRect(x: -1180.25, y: 1480.25, width: 300, height: 100)
        let crop = LearningReadingVisualPolicy.crop(region, frame: frame, pixels: CGSize(width: 2000, height: 1200))
        #expect(crop.pixels == CGRect(x: 39, y: 39, width: 601, height: 201))
        #expect(crop.screen.contains(region))
        #expect(LearningReadingVisualPolicy.screenRect(CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), in: frame)
            == CGRect(x: -700, y: 1300, width: 100, height: 60))
    }

    @Test func hitUsesExactOccurrenceThenSmallToleranceWithoutChoosingBetweenNeighbours() {
        let result = extraction()
        let pixels = CGSize(width: 1000, height: 400)
        #expect(LearningReadingVisualPolicy.hit(at: CGPoint(x: 0.52, y: 0.525), in: result, pixels: pixels)?.utf16Location == 8)
        #expect(LearningReadingVisualPolicy.hit(at: CGPoint(x: 0.552, y: 0.525), in: result, pixels: pixels)?.utf16Location == 8)
        #expect(LearningReadingVisualPolicy.hit(at: CGPoint(x: 0.7, y: 0.525), in: result, pixels: pixels) == nil)
        var words = result.words
        words.append(.init(text: "history", boundingBox: words[1].boundingBox,
            lineIndex: 0, utf16Location: 0, utf16Length: 7, confidence: 1))
        let ambiguous = ExtractedScreenText(text: result.text, lineCount: 1, lines: result.lines, words: words)
        #expect(LearningReadingVisualPolicy.hit(at: CGPoint(x: 0.52, y: 0.525), in: ambiguous, pixels: pixels) == nil)
    }

    @Test func invalidOffsetsAndLowConfidenceCannotBecomeAPointedWord() {
        let result = extraction()
        for word in [ScreenTextWord(text: "history", boundingBox: result.words[1].boundingBox,
                        lineIndex: 0, utf16Location: 9, utf16Length: 7, confidence: 1),
                     ScreenTextWord(text: "history", boundingBox: result.words[1].boundingBox,
                        lineIndex: 0, utf16Location: 8, utf16Length: 7, confidence: 0.1)] {
            #expect(LearningReadingVisualPolicy.hit(at: CGPoint(x: 0.52, y: 0.525),
                in: .init(text: result.text, lineCount: 1, lines: result.lines, words: [word]),
                pixels: CGSize(width: 1000, height: 400)) == nil)
        }
    }

    @Test func indivisibleHyphenBoxesReturnThePrintedCompoundRatherThanGuessingASubword() {
        let text = "OpenAI-compatible chat endpoint", box = CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05)
        let words = ["OpenAI", "compatible"].map { word in
            let range = (text as NSString).range(of: word)
            return ScreenTextWord(text: word, boundingBox: box, lineIndex: 0,
                utf16Location: range.location, utf16Length: range.length, confidence: 1)
        }
        let result = ExtractedScreenText(text: text, lineCount: 1,
            lines: [.init(text: text, confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.05))], words: words)
        let hit = LearningReadingVisualPolicy.hit(at: CGPoint(x: 0.25, y: 0.525), in: result, pixels: CGSize(width: 1000, height: 400))
        #expect(hit?.text == "OpenAI-compatible" && hit?.utf16Location == 0 && hit?.utf16Length == 17)
    }

    private func extraction() -> ExtractedScreenText {
        let text = "history history"
        return .init(text: text, lineCount: 1,
            lines: [.init(text: text, confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.05))],
            words: [0, 8].enumerated().map { index, offset in
                .init(text: "history", boundingBox: CGRect(x: index == 0 ? 0.1 : 0.5, y: 0.5, width: 0.05, height: 0.05),
                    lineIndex: 0, utf16Location: offset, utf16Length: 7, confidence: 1)
            })
    }
}
