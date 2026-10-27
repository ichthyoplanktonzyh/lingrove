import CoreGraphics
import Foundation
import NaturalLanguage
import Testing
@testable import Lingrove

/// A merged Vision observation can span two visual columns. Tests retain the original line
/// indices and UTF-16 offsets while checking that repeated spatial labels split only that layout.
struct LearningReadingOCRColumnsTests {
    @Test func repeatedAlignedSidebarSeparatesMergedLinesAndKeepsBothSourceRanges() throws {
        let extraction = fixture()
        let rows = LearningReadingOCRLayout.rows(extraction.lines, imageSize: CGSize(width: 1000, height: 400), words: extraction.words)
        #expect(rows.count == 4)
        for right in [false, true] {
            let matches = extraction.words.filter { $0.text == "history" }
            let word = try #require(right ? matches.last : matches.first)
            let block = try #require(LearningReadingOCRPolicy.block(word: word, lines: extraction.lines,
                imageSize: CGSize(width: 1000, height: 400), words: extraction.words))
            let context = try #require(block.context)
            #expect((context.text as NSString).substring(with: context.target) == "history")
            #expect(right ? context.text.contains("sidebar") : context.text.contains("Keep your"))
            #expect(right ? !context.text.contains("Keep your") : !context.text.contains("sidebar"))
            for source in block.sources {
                #expect((extraction.lines[source.lineIndex].text as NSString).substring(with: source.sourceRange) ==
                    (context.window.text as NSString).substring(with: source.windowRange))
            }
        }
    }

    @Test func oneRowOrDifferentHorizontalLocationsCannotCertifyAColumn() {
        let extraction = fixture()
        let oneLine = extraction.words.filter { $0.lineIndex == 0 }
        #expect(LearningReadingOCRColumns.split([extraction.lines[0]], words: oneLine,
            imageSize: CGSize(width: 1000, height: 400)).cuts.isEmpty)
        let shifted = extraction.words.map { word in
            ScreenTextWord(text: word.text, boundingBox: word.lineIndex == 1 ? word.boundingBox.offsetBy(dx: 0.1, dy: 0) : word.boundingBox,
                lineIndex: word.lineIndex, utf16Location: word.utf16Location, utf16Length: word.utf16Length)
        }
        #expect(LearningReadingOCRColumns.split(extraction.lines, words: shifted,
            imageSize: CGSize(width: 1000, height: 400)).cuts.isEmpty)
    }

    @Test func unsplitLinesPreserveWhitespaceAndExactUTF16Source() {
        let text = "  Visit the cafe\u{301} today.  "
        let line = OCRTextHygiene.OCRLine(text: text, confidence: 1, boundingBox: CGRect(x: 0, y: 0.5, width: 1, height: 0.1))
        let split = LearningReadingOCRColumns.split([line], words: [], imageSize: CGSize(width: 1000, height: 400))
        #expect(split.fragments.first?.line.text.utf16.elementsEqual(text.utf16) == true)
        #expect(split.fragments.first?.sourceRange == NSRange(location: 0, length: text.utf16.count))
    }

    @Test func repeatedOrdinaryProseDoesNotCreateAColumnBoundary() {
        let extraction = fixture()
        let line = extraction.lines[0]
        let copy = OCRTextHygiene.OCRLine(text: line.text, confidence: 1, boundingBox: line.boundingBox?.offsetBy(dx: 0, dy: -0.08))
        let first = extraction.words.filter { $0.lineIndex == 0 }
        let second = first.map { word in
            ScreenTextWord(text: word.text, boundingBox: word.boundingBox.offsetBy(dx: 0, dy: -0.08),
                lineIndex: 1, utf16Location: word.utf16Location, utf16Length: word.utf16Length)
        }
        #expect(LearningReadingOCRColumns.split([line, copy], words: first + second,
            imageSize: CGSize(width: 1000, height: 400)).cuts.isEmpty)
    }

    @Test func aLocalColumnCannotSplitDistantFullWidthProse() {
        let extraction = fixture()
        let line = extraction.lines[0]
        let outside = OCRTextHygiene.OCRLine(text: line.text, confidence: 1, boundingBox: line.boundingBox?.offsetBy(dx: 0, dy: -0.4))
        let words = extraction.words + extraction.words.filter { $0.lineIndex == 0 }.map { word in
            ScreenTextWord(text: word.text, boundingBox: word.boundingBox.offsetBy(dx: 0, dy: -0.4),
                lineIndex: 2, utf16Location: word.utf16Location, utf16Length: word.utf16Length)
        }
        let result = LearningReadingOCRColumns.split(extraction.lines + [outside], words: words,
            imageSize: CGSize(width: 1000, height: 400))
        #expect(!result.cuts.isEmpty)
        #expect(result.fragments.filter { $0.sourceIndex == 2 }.count == 1)
        #expect(result.fragments.last?.line.text == line.text)
    }

    private func fixture() -> ExtractedScreenText {
        let texts = ["Earlier sentence. Keep your review Repeated sidebar label starts.",
                     "history safe. Next sentence. Repeated sidebar label history ends."]
        var lines: [OCRTextHygiene.OCRLine] = [], words: [ScreenTextWord] = []
        for (index, text) in texts.enumerated() {
            let y = 0.6 - CGFloat(index) * 0.08
            lines.append(.init(text: text, confidence: 1, boundingBox: CGRect(x: 0.05, y: y, width: 0.9, height: 0.05)))
            let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
            var x: CGFloat = 0.05
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let token = String(text[range]), offset = NSRange(range, in: text)
                if token == "Repeated" { x = 0.6 }
                let width = CGFloat(token.utf16.count) * 0.006
                words.append(.init(text: token, boundingBox: CGRect(x: x, y: y, width: width, height: 0.05),
                    lineIndex: index, utf16Location: offset.location, utf16Length: offset.length, confidence: 1))
                x += width + 0.004
                return true
            }
        }
        return .init(text: texts.joined(separator: "\n"), lineCount: 2, lines: lines, words: words)
    }
}
