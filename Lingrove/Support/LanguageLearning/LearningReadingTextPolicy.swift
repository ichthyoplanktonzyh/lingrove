import CoreGraphics
import Foundation
import NaturalLanguage

/// Deterministic geometry and text rules shared by pointer AX and screenshot OCR. Keeping these
/// outside the OS boundary makes target integrity testable without screen permissions or a model.
nonisolated enum LearningReadingTextPolicy {
    /// ScreenCaptureKit's sourceRect is local to its matched display and has a top-left origin.
    /// Work in display-local points; the display's backing scale is applied only to output pixels.
    static func displayCrop(_ rect: CGRect, in screen: CGRect) -> CGRect {
        CGRect(x: rect.minX - screen.minX, y: screen.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A pointed word must contain the character hit by AX, not a nearby label or whole page.
    /// Tokenizer offsets are UTF-16 at the boundary, matching Accessibility's range convention.
    static func word(in text: String, utf16Index: Int) -> (text: String, range: NSRange)? {
        guard utf16Index >= 0, utf16Index < text.utf16.count,
            let index = String.Index(utf16Offset: utf16Index, in: text).samePosition(in: text)
        else { return nil }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let range = tokenizer.tokenRange(at: index)
        guard !range.isEmpty, range.contains(index), text[range].contains(where: \.isLetter) else {
            return nil
        }
        return (String(text[range]), NSRange(range, in: text))
    }

    /// Translate every recognized line, including low-confidence lines. Context hygiene is not
    /// appropriate here: dropping a line would change the user's target. Whitespace cuts recover
    /// simple columns; conservative line breaks preserve ambiguous layouts rather than rewriting.
    static func text(from lines: [OCRTextHygiene.OCRLine]) throws -> String {
        let text = ordered(lines).map(\.text).joined(separator: "\n")
        try LearningReadingPolicy.validate(text)
        return text
    }

    static func ordered(_ lines: [OCRTextHygiene.OCRLine]) -> [OCRTextHygiene.OCRLine] {
        ordered(lines, depth: 0)
    }

    private static func ordered(_ lines: [OCRTextHygiene.OCRLine], depth: Int) -> [OCRTextHygiene.OCRLine] {
        guard lines.count > 1, lines.allSatisfy({ $0.boundingBox != nil }) else { return lines }
        let rows = lines.sorted {
            if ($0.boundingBox ?? .zero).midY != ($1.boundingBox ?? .zero).midY {
                return ($0.boundingBox ?? .zero).midY > ($1.boundingBox ?? .zero).midY
            }
            return ($0.boundingBox ?? .zero).minX < ($1.boundingBox ?? .zero).minX
        }
        guard depth < 16 else { return rows }
        let byX = lines.sorted { ($0.boundingBox ?? .zero).minX < ($1.boundingBox ?? .zero).minX }
        var right = (byX[0].boundingBox ?? .zero).maxX
        for index in 1..<byX.count {
            if (byX[index].boundingBox ?? .zero).minX - right > 0.035 {
                return ordered(Array(byX[..<index]), depth: depth + 1) + ordered(Array(byX[index...]), depth: depth + 1)
            }
            right = max(right, (byX[index].boundingBox ?? .zero).maxX)
        }
        // A heading spanning both columns can hide their vertical whitespace. Split independent
        // horizontal bands first, then recover each band's columns; cap depth for adversarial layouts.
        var bottom = (rows[0].boundingBox ?? .zero).minY
        for index in 1..<rows.count {
            if bottom - (rows[index].boundingBox ?? .zero).maxY > 0.02 {
                return ordered(Array(rows[..<index]), depth: depth + 1) + ordered(Array(rows[index...]), depth: depth + 1)
            }
            bottom = min(bottom, (rows[index].boundingBox ?? .zero).minY)
        }
        return rows
    }

}
