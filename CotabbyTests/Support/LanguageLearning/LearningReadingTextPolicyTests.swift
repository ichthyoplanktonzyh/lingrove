import CoreGraphics
import Foundation
import Testing

@testable import Cotabby

@Suite struct LearningReadingTextPolicyTests {
    @Test func columnsKeepTheirReadingOrderAndLowConfidenceText() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(
                text: "Right second", confidence: 1,
                boundingBox: .init(x: 0.6, y: 0.6, width: 0.3, height: 0.1)),
            .init(
                text: "Left first", confidence: 1,
                boundingBox: .init(x: 0.1, y: 0.8, width: 0.3, height: 0.1)),
            .init(
                text: "Right first", confidence: 1,
                boundingBox: .init(x: 0.6, y: 0.8, width: 0.3, height: 0.1)),
            .init(
                text: "Left uncertain", confidence: 0.1,
                boundingBox: .init(x: 0.1, y: 0.6, width: 0.3, height: 0.1)),
        ]
        #expect(
            try LearningReadingTextPolicy.text(from: lines)
                == "Left first\nLeft uncertain\nRight first\nRight second")
    }
    @Test func spanningHeadingDoesNotInterleaveColumns() throws {
        let lines: [OCRTextHygiene.OCRLine] = [
            .init(text: "Heading", confidence: 1, boundingBox: .init(x: 0.1, y: 0.92, width: 0.8, height: 0.05)),
            .init(text: "Left one", confidence: 1, boundingBox: .init(x: 0.1, y: 0.75, width: 0.3, height: 0.06)),
            .init(text: "Right one", confidence: 1, boundingBox: .init(x: 0.6, y: 0.75, width: 0.3, height: 0.06)),
            .init(text: "Left two", confidence: 1, boundingBox: .init(x: 0.1, y: 0.65, width: 0.3, height: 0.06)),
            .init(text: "Right two", confidence: 1, boundingBox: .init(x: 0.6, y: 0.65, width: 0.3, height: 0.06)),
        ]
        #expect(try LearningReadingTextPolicy.text(from: lines) == "Heading\nLeft one\nLeft two\nRight one\nRight two")
    }

    @Test func missingGeometryDoesNotDropOrInventText() throws {
        let text = try LearningReadingTextPolicy.text(from: [
            .init(text: "keep-", confidence: 0), .init(text: "posted", confidence: 1),
        ])
        #expect(text == "keep-\nposted")
    }
    @Test func oversizedOCRTargetFailsWhole() {
        let oversized = String(repeating: "a", count: ModelContextBudget.maximumTextBytes + 1)
        #expect(throws: (any Error).self) {
            try LearningReadingTextPolicy.text(from: [.init(text: oversized, confidence: 1)])
        }
    }
    @Test func wordUsesUTF16OffsetsAndRejectsWhitespace() {
        let text = "👋 Please keep me posted."
        let range = (text as NSString).range(of: "posted")
        let result = LearningReadingTextPolicy.word(in: text, utf16Index: range.location + 2)
        #expect(result?.text == "posted")
        #expect(result?.range == range)
        #expect(LearningReadingTextPolicy.word(in: text, utf16Index: 2) == nil)
        #expect(LearningReadingTextPolicy.word(in: text, utf16Index: -1) == nil)
        #expect(LearningReadingTextPolicy.word(in: text, utf16Index: text.utf16.count) == nil)
    }
    @Test func displayLocalCropsHaveAbsoluteExpectedCoordinates() {
        let abovePrimary = CGRect(x: 0, y: 900, width: 1440, height: 900)
        #expect(
            LearningReadingTextPolicy.displayCrop(CGRect(x: 50, y: 1500, width: 200, height: 100), in: abovePrimary)
                == CGRect(x: 50, y: 200, width: 200, height: 100))
        let leftRetina = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        #expect(
            LearningReadingTextPolicy.displayCrop(CGRect(x: -1400, y: 120, width: 800, height: 300), in: leftRetina)
                == CGRect(x: 40, y: 480, width: 800, height: 300))
    }
}
