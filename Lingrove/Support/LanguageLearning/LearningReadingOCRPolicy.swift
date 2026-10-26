import CoreGraphics
import Foundation

/// Reconstructs a small continuous reading block around a geometrically hit OCR word. Original
/// line text and exact UTF-16 offsets remain authoritative; this policy never repairs spelling or
/// invents text outside the screenshot. The reader releases these values with its capture.
nonisolated enum LearningReadingOCRPolicy {
    struct Block {
        let context: LearningReadingContext?
        let bounds: CGRect
        let sources: [Source]
    }

    /// Maps the bounded reconstructed window back to its emitted OCR lines. Explicit selection
    /// alignment uses this provenance to distinguish repeated strings without searching a page.
    struct Source {
        let lineIndex: Int
        let sourceRange: NSRange
        let windowRange: NSRange
    }

    static func context(word: ScreenTextWord, lines: [OCRTextHygiene.OCRLine],
                        imageSize: CGSize = CGSize(width: 1, height: 1)) -> LearningReadingContext? {
        block(word: word, lines: lines, imageSize: imageSize)?.context
    }

    static func block(word: ScreenTextWord, lines: [OCRTextHygiene.OCRLine], imageSize: CGSize) -> Block? {
        guard imageSize.width > 0, imageSize.height > 0, imageSize.width.isFinite, imageSize.height.isFinite,
              lines.count <= 2_048, let sourceIndex = word.lineIndex, lines.indices.contains(sourceIndex),
              let location = word.utf16Location, let length = word.utf16Length,
              let box = lines[sourceIndex].boundingBox else { return nil }
        let sourceRange = NSRange(location: location, length: length)
        guard VocabularyPolicy.valid(sourceRange, in: lines[sourceIndex].text),
              (lines[sourceIndex].text as NSString).substring(with: sourceRange).utf16.elementsEqual(word.text.utf16),
              box.intersects(word.boundingBox) else { return nil }
        let rows = LearningReadingOCRLayout.rows(lines, imageSize: imageSize)
        guard let index = rows.firstIndex(where: { $0.sources[sourceIndex] != nil }),
              let source = rows[index].sources[sourceIndex] else { return nil }
        let lines = rows.map(\.line)
        let range = NSRange(location: source.location + location, length: length)
        // Only similarly aligned, adjacent lines may join. A gap/column/layout change stops the
        // walk; retaining an honest fragment is preferable to splicing unrelated screen regions.
        let budget = LearningReadingContextPolicy.maximumSurroundingUTF16 - (lines[index].text.utf16.count - word.text.utf16.count)
        if budget < 0 {
            guard let crop = boundedRange(in: lines[index].text, target: range)
            else { return nil }
            let window = LearningReadingWindow(text: (lines[index].text as NSString).substring(with: crop),
                target: NSRange(location: range.location - crop.location, length: range.length),
                left: .crop, right: .crop, method: .ocr, confidence: lines[index].confidence)
            return Block(context: LearningReadingContextPolicy.resolve(window, expected: word.text), bounds: box,
                sources: sources(rows[index], at: 0, clipping: crop))
        }
        let included = connectedIndices(lines, index: index, budget: budget, imageSize: imageSize)
        var text = "", targetOffset = 0, sources: [Source] = []
        for current in included {
            text += LearningReadingOCRLayout.separator(text, lines[current].text)
            if current == index { targetOffset = text.utf16.count + range.location }
            sources += self.sources(rows[current], at: text.utf16.count)
            text += lines[current].text
        }
        let window = LearningReadingWindow(text: text,
            target: NSRange(location: targetOffset, length: length), left: .crop, right: .crop, method: .ocr,
            confidence: included.map { lines[$0].confidence }.min())
        let bounds = included.compactMap { lines[$0].boundingBox }.reduce(CGRect.null) { $0.union($1) }
        return Block(context: LearningReadingContextPolicy.resolve(window, expected: word.text), bounds: bounds, sources: sources)
    }

    private static func sources(_ row: LearningReadingOCRLayout.Row, at offset: Int, clipping: NSRange? = nil) -> [Source] {
        let clip = clipping ?? NSRange(location: 0, length: row.line.text.utf16.count)
        return row.sources.compactMap { index, range in
            let visible = NSIntersectionRange(range, clip)
            guard visible.length > 0 else { return nil }
            return Source(lineIndex: index,
                sourceRange: NSRange(location: visible.location - range.location, length: visible.length),
                windowRange: NSRange(location: offset + visible.location - clip.location, length: visible.length))
        }
    }

    private static func boundedRange(in text: String, target: NSRange) -> NSRange? {
        let raw = text as NSString
        guard let requested = LearningReadingContextPolicy.windowRange(target: target, count: raw.length) else { return nil }
        var lower = requested.location, upper = NSMaxRange(requested)
        let first = raw.rangeOfComposedCharacterSequence(at: lower)
        if first.location < lower { lower = NSMaxRange(first) }
        let last = raw.rangeOfComposedCharacterSequence(at: upper - 1)
        if NSMaxRange(last) > upper { upper = last.location }
        guard lower <= target.location, upper >= NSMaxRange(target) else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func connectedIndices(_ lines: [OCRTextHygiene.OCRLine], index: Int,
                                         budget: Int, imageSize: CGSize) -> [Int] {
        var included = [index], budget = budget
        var edges = [index, index], active = [true, true]
        for _ in 0..<8 {
            for side in 0..<2 where active[side] {
                let edge = edges[side]
                let candidates = lines.indices.filter { candidate in
                    guard !included.contains(candidate), let rect = lines[candidate].boundingBox,
                          let edgeRect = lines[edge].boundingBox,
                          side == 0 ? rect.midY > edgeRect.midY : rect.midY < edgeRect.midY else { return false }
                    let lower = side == 0 ? lines[edge] : lines[candidate]
                    return !LearningReadingOCRLayout.startsListItem(lower.text) &&
                        continuous(lines[edge], lines[candidate], imageSize: imageSize)
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
        return included
    }

    private static func continuous(_ first: OCRTextHygiene.OCRLine, _ second: OCRTextHygiene.OCRLine,
                                   imageSize: CGSize) -> Bool {
        // Vision normalizes x and y independently. Compare physical dimensions, otherwise wide
        // screenshot crops make the horizontal alignment tolerance several times too generous.
        let scale = CGAffineTransform(scaleX: imageSize.width, y: imageSize.height)
        guard let left = first.boundingBox?.applying(scale), let right = second.boundingBox?.applying(scale),
              left.height > 0, right.height > 0 else { return false }
        let upperLine = left.midY > right.midY ? first : second
        let upper = left.midY > right.midY ? left : right, lower = left.midY > right.midY ? right : left
        // A wrapped list item hangs under its text, to the right of its bullet. A new unindented
        // block below a bullet must not inherit that item's label as contextual prose.
        if LearningReadingOCRLayout.startsListItem(upperLine.text), lower.minX - upper.minX < upper.height * 0.3 { return false }
        let height = max(left.height, right.height)
        let overlap = max(0, min(left.maxX, right.maxX) - max(left.minX, right.minX))
        return max(left.height, right.height) / min(left.height, right.height) < 1.6 &&
            abs(left.midY - right.midY) > height * 0.6 &&
            abs(left.midY - right.midY) < min(left.height, right.height) * 2.2 &&
            abs(left.minX - right.minX) < height * 2 && overlap >= min(left.width, right.width) * 0.65
    }
}
