import CoreGraphics
import Foundation

/// Reconstructs a small continuous reading block around a geometrically hit OCR word. Original
/// line text and exact UTF-16 offsets remain authoritative; this policy never repairs spelling or
/// invents text outside the screenshot. The reader releases these values with its capture.
nonisolated enum LearningReadingOCRPolicy {
    static func context(word: ScreenTextWord, lines: [OCRTextHygiene.OCRLine],
                        imageSize: CGSize = CGSize(width: 1, height: 1)) -> LearningReadingContext? {
        guard imageSize.width > 0, imageSize.height > 0, imageSize.width.isFinite, imageSize.height.isFinite,
              let index = word.lineIndex, lines.indices.contains(index),
              let location = word.utf16Location, let length = word.utf16Length,
              let box = lines[index].boundingBox else { return nil }
        let range = NSRange(location: location, length: length)
        guard VocabularyPolicy.valid(range, in: lines[index].text),
              (lines[index].text as NSString).substring(with: range).utf16.elementsEqual(word.text.utf16),
              box.intersects(word.boundingBox) else { return nil }
        // Only similarly aligned, adjacent lines may join. A gap/column/layout change stops the
        // walk; retaining an honest fragment is preferable to splicing unrelated screen regions.
        var included = [index]
        var budget = LearningReadingContextPolicy.maximumSurroundingUTF16 - (lines[index].text.utf16.count - word.text.utf16.count)
        guard budget >= 0 else { return nil }
        var edges = [index, index], active = [true, true]
        for _ in 0..<8 {
            for side in 0..<2 where active[side] {
                let edge = edges[side]
                let candidates = lines.indices.filter { candidate in
                    guard !included.contains(candidate), let rect = lines[candidate].boundingBox,
                          let edgeRect = lines[edge].boundingBox,
                          side == 0 ? rect.midY > edgeRect.midY : rect.midY < edgeRect.midY else { return false }
                    return continuous(lines[edge], lines[candidate], imageSize: imageSize)
                }
                guard let next = candidates.min(by: {
                    abs((lines[$0].boundingBox?.midY ?? 0) - (lines[edge].boundingBox?.midY ?? 0)) <
                        abs((lines[$1].boundingBox?.midY ?? 0) - (lines[edge].boundingBox?.midY ?? 0))
                }), lines[next].text.utf16.count + 1 <= budget else { active[side] = false; continue }
                if side == 0 { included.insert(next, at: 0) } else { included.append(next) }
                budget -= lines[next].text.utf16.count + 1
                edges[side] = next
            }
        }
        var text = "", targetOffset = 0
        for current in included {
            text += separator(text, lines[current].text)
            if current == index { targetOffset = text.utf16.count + location }
            text += lines[current].text
        }
        let window = LearningReadingWindow(text: text,
            target: NSRange(location: targetOffset, length: length), left: .crop, right: .crop, method: .ocr,
            confidence: included.map { lines[$0].confidence }.min())
        return LearningReadingContextPolicy.resolve(window, expected: word.text)
    }

    private static func continuous(_ first: OCRTextHygiene.OCRLine, _ second: OCRTextHygiene.OCRLine,
                                   imageSize: CGSize) -> Bool {
        // Vision normalizes x and y independently. Compare physical dimensions, otherwise wide
        // screenshot crops make the horizontal alignment tolerance several times too generous.
        let scale = CGAffineTransform(scaleX: imageSize.width, y: imageSize.height)
        guard let left = first.boundingBox?.applying(scale), let right = second.boundingBox?.applying(scale),
              left.height > 0, right.height > 0 else { return false }
        let height = max(left.height, right.height)
        let overlap = max(0, min(left.maxX, right.maxX) - max(left.minX, right.minX))
        return max(left.height, right.height) / min(left.height, right.height) < 1.6 &&
            abs(left.midY - right.midY) > height * 0.6 && abs(left.midY - right.midY) < height * 2.2 &&
            abs(left.minX - right.minX) < height * 2 && overlap >= min(left.width, right.width) * 0.65
    }
    private static func separator(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first,
              !last.isWhitespace, !first.isWhitespace, last != "-" else { return "" }
        // Chinese/Japanese soft wraps do not introduce word spaces. Retain visible hyphens;
        // deciding that a printed hyphen is discretionary would change the captured original.
        let cjk = #"^[\p{Han}\p{Hiragana}\p{Katakana}，。！？、」』]$"#
        if String(last).range(of: cjk, options: .regularExpression) != nil &&
            String(first).range(of: cjk, options: .regularExpression) != nil { return "" }
        return " "
    }

}
