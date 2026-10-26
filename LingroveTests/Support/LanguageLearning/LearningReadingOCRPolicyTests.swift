import CoreGraphics
import Foundation
import Testing

@testable import Lingrove

@Suite
struct LearningReadingOCRPolicyTests {
    @Test func repeatedWordKeepsItsExactOccurrence() throws {
        let line = "The bank was beside another bank."
        let range = (line as NSString).range(of: "bank", options: .backwards)
        let word = ScreenTextWord(text: "bank", boundingBox: CGRect(x: 0.7, y: 0.5, width: 0.1, height: 0.04),
            lineIndex: 0, utf16Location: range.location, utf16Length: range.length, confidence: 0.9)
        let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: [
            .init(text: line, confidence: 0.9, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.04))
        ]))
        #expect(context.target == range)
        #expect(context.window.confidence == 0.9)
        #expect(!context.isComplete)
    }

    @Test func adjacentLinesJoinWithoutLosingTargetOffsetOrConfidence() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "An earlier sentence. We preserve", confidence: 0.95,
                boundingBox: CGRect(x: 0.1, y: 0.55, width: 0.8, height: 0.04)),
            .init(text: "your review history. Another sentence.", confidence: 0.75,
                boundingBox: CGRect(x: 0.1, y: 0.50, width: 0.8, height: 0.04))
        ]
        let word = ScreenTextWord(text: "history", boundingBox: CGRect(x: 0.4, y: 0.50, width: 0.1, height: 0.04),
            lineIndex: 1, utf16Location: 12, utf16Length: 7)
        let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines))
        #expect(context.text.trimmingCharacters(in: .whitespacesAndNewlines) == "We preserve your review history.")
        #expect(context.isComplete)
        #expect((context.text as NSString).substring(with: context.target) == "history")
        #expect(context.window.confidence == 0.75)
    }

    @Test func otherColumnAndLargeGapDoNotEnterTheContext() throws {
        let word = ScreenTextWord(text: "history", boundingBox: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.04),
            lineIndex: 1, utf16Location: 5, utf16Length: 7)
        for rect in [CGRect(x: 0.6, y: 0.55, width: 0.3, height: 0.04),
                     CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.04)] {
            let result = try #require(LearningReadingOCRPolicy.context(word: word, lines: [
                .init(text: "Unrelated navigation", confidence: 1, boundingBox: rect),
                .init(text: "Your history remains.", confidence: 0.9,
                    boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.04))
            ]))
            #expect(!result.window.text.contains("Unrelated"))
            #expect(!result.isComplete)
        }
    }

    @Test func anotherColumnBetweenRowsCannotInterruptThisColumnsContext() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "Earlier sentence. Keep", confidence: 0.9,
                boundingBox: CGRect(x: 0.05, y: 0.55, width: 0.35, height: 0.04)),
            .init(text: "Unrelated sidebar", confidence: 0.9,
                boundingBox: CGRect(x: 0.60, y: 0.54, width: 0.35, height: 0.04)),
            .init(text: "your history safe. Next sentence.", confidence: 0.9,
                boundingBox: CGRect(x: 0.05, y: 0.50, width: 0.35, height: 0.04))
        ]
        let word = ScreenTextWord(text: "history", boundingBox: CGRect(x: 0.12, y: 0.5, width: 0.07, height: 0.04),
            lineIndex: 2, utf16Location: 5, utf16Length: 7)
        let result = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines, imageSize: CGSize(width: 900, height: 300)))
        #expect(result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Keep your history safe.")
    }

    @Test func alignmentUsesPhysicalPixelsForWideScreenshots() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "Wrong indented block", confidence: 0.9,
                boundingBox: CGRect(x: 0.15, y: 0.55, width: 0.3, height: 0.04)),
            .init(text: "Your history remains.", confidence: 0.9,
                boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.04))
        ]
        let word = ScreenTextWord(text: "history", boundingBox: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.04),
            lineIndex: 1, utf16Location: 5, utf16Length: 7)
        let result = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines, imageSize: CGSize(width: 1000, height: 200)))
        #expect(!result.window.text.contains("Wrong"))
    }

    @Test func chineseSoftWrapDoesNotInsertAWordSpace() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "这是前一句。我们需要", confidence: 0.9,
                boundingBox: CGRect(x: 0.1, y: 0.55, width: 0.8, height: 0.04)),
            .init(text: "保留历史记录。下一句。", confidence: 0.9,
                boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.04))
        ]
        let word = ScreenTextWord(text: "历史记录", boundingBox: CGRect(x: 0.3, y: 0.5, width: 0.2, height: 0.04),
            lineIndex: 1, utf16Location: 2, utf16Length: 4)
        let result = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines))
        #expect(result.text == "我们需要保留历史记录。")
        #expect((result.text as NSString).substring(with: result.target) == "历史记录")
    }

    @Test func missingOrMismatchedOffsetsCannotInventAnOccurrence() {
        let line = OCRTextHygiene.OCRLine(text: "history history", confidence: 0.8, boundingBox: .unit)
        for word in [ScreenTextWord(text: "history", boundingBox: .unit),
                     ScreenTextWord(text: "history", boundingBox: .unit, lineIndex: 0, utf16Location: 2, utf16Length: 7)] {
            #expect(LearningReadingOCRPolicy.context(word: word, lines: [line]) == nil)
        }
    }
}

private extension CGRect {
    static var unit: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }
}
