import CoreGraphics
import Foundation
import Testing

@testable import Lingrove

@Suite
struct LearningReadingOCRPolicyTests {
    @Test func inflatedVisionRowEnvelopeCanRetainAnAlignedWrappedSentence() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "Earlier sentence. Keep your review", confidence: 1,
                boundingBox: CGRect(x: 0.046, y: 0.58, width: 0.375, height: 0.083)),
            .init(text: "history safe. Another sentence.", confidence: 1,
                boundingBox: CGRect(x: 0.042, y: 0.432, width: 0.376, height: 0.136))
        ]
        let word = ScreenTextWord(text: "history", boundingBox: CGRect(x: 0.042, y: 0.432, width: 0.084, height: 0.136),
            lineIndex: 1, utf16Location: 0, utf16Length: 7)
        let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines, imageSize: CGSize(width: 1000, height: 241)))
        #expect(context.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Keep your review history safe.")
    }

    @Test func corroboratedNarrowColumnsNeverBecomeOneSentence() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "Earlier sentence. Keep your", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.56, width: 0.3, height: 0.05)),
            .init(text: "Unrelated right column starts", confidence: 1, boundingBox: CGRect(x: 0.412, y: 0.56, width: 0.3, height: 0.05)),
            .init(text: "history safe. Next sentence.", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.50, width: 0.3, height: 0.05)),
            .init(text: "Unrelated right column ends.", confidence: 1, boundingBox: CGRect(x: 0.412, y: 0.50, width: 0.3, height: 0.05))
        ]
        let word = ScreenTextWord(text: "history", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.08, height: 0.05),
            lineIndex: 2, utf16Location: 0, utf16Length: 7)
        let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines, imageSize: CGSize(width: 1000, height: 400)))
        #expect(context.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Keep your history safe.")
        #expect(!context.window.text.contains("Unrelated"))
    }

    @Test func tallerInlineEmphasisRetainsItsSourceOffsetAndSentence() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "Earlier sentence. Keep your", confidence: 1, boundingBox: CGRect(x: 0.05, y: 0.5, width: 0.4, height: 0.05)),
            .init(text: "history", confidence: 1, boundingBox: CGRect(x: 0.455, y: 0.5, width: 0.1, height: 0.08)),
            .init(text: "safe. Next sentence.", confidence: 1, boundingBox: CGRect(x: 0.56, y: 0.5, width: 0.3, height: 0.05))
        ]
        let word = ScreenTextWord(text: "history", boundingBox: lines[1].boundingBox!, lineIndex: 1, utf16Location: 0, utf16Length: 7)
        let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines, imageSize: CGSize(width: 1000, height: 400)))
        #expect(context.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Keep your history safe.")
        #expect((context.text as NSString).substring(with: context.target) == "history")
    }

    @Test func anInterveningIncompatibleRowStopsExpansionInsteadOfBeingSkipped() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "Unrelated preceding prose", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.56, width: 0.5, height: 0.04)),
            .init(text: "Small separate heading", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.536, width: 0.3, height: 0.02)),
            .init(text: "Keep your history safe.", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.04))
        ]
        let word = ScreenTextWord(text: "history", boundingBox: CGRect(x: 0.25, y: 0.5, width: 0.1, height: 0.04),
            lineIndex: 2, utf16Location: 10, utf16Length: 7)
        let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines, imageSize: CGSize(width: 1000, height: 400)))
        #expect(context.window.text == "Keep your history safe.")
    }

    @Test func interiorImageTextHasUnknownEdgesWhileActualImageCutsRemainFragments() throws {
        let text = "The report is ready."
        let target = (text as NSString).range(of: "report")
        for (box, expected) in [(CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.05), VocabularyExample.Completeness.unknown),
                                (CGRect(x: 0, y: 0.5, width: 0.6, height: 0.05), .fragment)] {
            let word = ScreenTextWord(text: "report", boundingBox: box, lineIndex: 0,
                utf16Location: target.location, utf16Length: target.length)
            let context = try #require(LearningReadingOCRPolicy.context(word: word,
                lines: [.init(text: text, confidence: 1, boundingBox: box)], imageSize: CGSize(width: 1000, height: 400)))
            #expect(context.completeness == expected)
        }
    }
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

    @Test func sameRowLinkFragmentsPreserveExactSourceOffsets() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "Earlier sentence. Keep your", confidence: 0.95,
                boundingBox: CGRect(x: 0.05, y: 0.50, width: 0.40, height: 0.05)),
            .init(text: "history", confidence: 0.85,
                boundingBox: CGRect(x: 0.455, y: 0.50, width: 0.10, height: 0.05)),
            .init(text: "safe. Next sentence.", confidence: 0.9,
                boundingBox: CGRect(x: 0.56, y: 0.50, width: 0.30, height: 0.05))
        ]
        let word = ScreenTextWord(text: "history", boundingBox: lines[1].boundingBox!,
            lineIndex: 1, utf16Location: 0, utf16Length: 7)
        let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines, imageSize: CGSize(width: 1000, height: 400)))
        #expect(context.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Keep your history safe.")
        #expect((context.text as NSString).substring(with: context.target) == "history")
        #expect(context.isComplete && context.window.confidence == 0.85)
    }

    @Test func separateListItemsAndDistantSameRowCellsStaySeparate() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "• Unrelated first item", confidence: 1,
                boundingBox: CGRect(x: 0.1, y: 0.56, width: 0.3, height: 0.04)),
            .init(text: "• Your history remains.", confidence: 1,
                boundingBox: CGRect(x: 0.1, y: 0.50, width: 0.3, height: 0.04)),
            .init(text: "Unrelated table cell", confidence: 1,
                boundingBox: CGRect(x: 0.5, y: 0.50, width: 0.3, height: 0.04))
        ]
        let word = ScreenTextWord(text: "history", boundingBox: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.04),
            lineIndex: 1, utf16Location: 7, utf16Length: 7)
        let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines, imageSize: CGSize(width: 1000, height: 400)))
        #expect(!context.window.text.contains("Unrelated"))
        #expect(!context.isComplete)
    }

    @Test func oversizedRowKeepsABoundedWindowAroundTheExactTarget() throws {
        let text = String(repeating: "👩🏽‍💻 before ", count: 150) + "history " + String(repeating: "after é ", count: 150)
        let range = (text as NSString).range(of: "history")
        let word = ScreenTextWord(text: "history", boundingBox: .unit,
            lineIndex: 0, utf16Location: range.location, utf16Length: range.length)
        let context = try #require(LearningReadingOCRPolicy.context(word: word,
            lines: [.init(text: text, confidence: 1, boundingBox: .unit)]))
        #expect(context.window.text.utf16.count <= 1024 + range.length)
        #expect((context.text as NSString).substring(with: context.target) == "history")
        #expect(!context.window.text.contains("\u{FFFD}"))
        #expect(!context.isComplete)
    }

    @Test func headingAndUnindentedParagraphAfterAListAreSeparateBlocks() throws {
        for upper in [OCRTextHygiene.OCRLine(text: "Reading fixture", confidence: 1,
                         boundingBox: CGRect(x: 0.1, y: 0.62, width: 0.35, height: 0.06)),
                      OCRTextHygiene.OCRLine(text: "• Unrelated label", confidence: 1,
                         boundingBox: CGRect(x: 0.1, y: 0.56, width: 0.35, height: 0.04))] {
            let lines = [upper, OCRTextHygiene.OCRLine(text: "Your history remains.", confidence: 1,
                boundingBox: CGRect(x: 0.1, y: 0.50, width: 0.35, height: 0.04))]
            let word = ScreenTextWord(text: "history", boundingBox: CGRect(x: 0.2, y: 0.50, width: 0.1, height: 0.04),
                lineIndex: 1, utf16Location: 5, utf16Length: 7)
            let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines,
                imageSize: CGSize(width: 1000, height: 400)))
            #expect(context.window.text == "Your history remains.")
        }
    }

    @Test func hangingListContinuationRetainsItsOwnFirstLine() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "• Keep your review", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.56, width: 0.35, height: 0.04)),
            .init(text: "history safe.", confidence: 1, boundingBox: CGRect(x: 0.11, y: 0.50, width: 0.3, height: 0.04))]
        let word = ScreenTextWord(text: "history", boundingBox: CGRect(x: 0.11, y: 0.5, width: 0.1, height: 0.04),
            lineIndex: 1, utf16Location: 0, utf16Length: 7)
        let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: lines, imageSize: CGSize(width: 1000, height: 400)))
        #expect(context.text.contains("Keep your review history safe."))
    }
}

private extension CGRect {
    static var unit: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }
}
