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

    static func block(word: ScreenTextWord, lines: [OCRTextHygiene.OCRLine], imageSize: CGSize,
                      words: [ScreenTextWord] = [], preparedRows: [LearningReadingOCRLayout.Row]? = nil) -> Block? {
        guard imageSize.width > 0, imageSize.height > 0, imageSize.width.isFinite, imageSize.height.isFinite,
              lines.count <= 2_048, let sourceIndex = word.lineIndex, lines.indices.contains(sourceIndex),
              let location = word.utf16Location, let length = word.utf16Length,
              let box = lines[sourceIndex].boundingBox else { return nil }
        let sourceRange = NSRange(location: location, length: length)
        guard VocabularyPolicy.valid(sourceRange, in: lines[sourceIndex].text),
              (lines[sourceIndex].text as NSString).substring(with: sourceRange).utf16.elementsEqual(word.text.utf16),
              box.intersects(word.boundingBox) else { return nil }
        let rows = preparedRows ?? LearningReadingOCRLayout.rows(lines, imageSize: imageSize, words: words)
        guard let index = rows.firstIndex(where: {
            $0.sources[sourceIndex].map { location >= $0.original.location && location + length <= NSMaxRange($0.original) } ?? false
        }),
              let source = rows[index].sources[sourceIndex] else { return nil }
        let lines = rows.map(\.line)
        let range = NSRange(location: source.row.location + location - source.original.location, length: length)
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
        let edges = boundaries(included.compactMap { lines[$0].boundingBox }, imageSize: imageSize)
        let window = LearningReadingWindow(text: text,
            target: NSRange(location: targetOffset, length: length), left: edges.left, right: edges.right, method: .ocr,
            confidence: included.map { lines[$0].confidence }.min())
        let bounds = included.compactMap { lines[$0].boundingBox }.reduce(CGRect.null) { $0.union($1) }
        return Block(context: LearningReadingContextPolicy.resolve(window, expected: word.text), bounds: bounds, sources: sources)
    }

    /// An interior OCR block has unverified outer boundaries, not proven missing words. Keep
    /// a crop warning only where text reaches the image edge (or the separate character-budget
    /// path actually clips a row). Whitespace inside the image alone cannot certify a sentence.
    private static func boundaries(_ rows: [CGRect], imageSize: CGSize)
        -> (left: LearningReadingWindow.Boundary, right: LearningReadingWindow.Boundary) {
        guard imageSize.width >= 4, imageSize.height >= 4, let first = rows.first, let last = rows.last else {
            return (.unknown, .unknown)
        }
        let xMargin = 3 / imageSize.width, yMargin = 3 / imageSize.height
        let horizontalCrop = rows.contains { $0.minX <= xMargin || $0.maxX >= 1 - xMargin }
        return (horizontalCrop || first.maxY >= 1 - yMargin ? .crop : .unknown,
                horizontalCrop || last.minY <= yMargin ? .crop : .unknown)
    }

    private static func sources(_ row: LearningReadingOCRLayout.Row, at offset: Int, clipping: NSRange? = nil) -> [Source] {
        let clip = clipping ?? NSRange(location: 0, length: row.line.text.utf16.count)
        return row.sources.compactMap { index, source in
            let visible = NSIntersectionRange(source.row, clip)
            guard visible.length > 0 else { return nil }
            return Source(lineIndex: index,
                sourceRange: NSRange(location: source.original.location + visible.location - source.row.location, length: visible.length),
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
        let pitch = typicalPitch(lines, index: index, imageSize: imageSize)
        for _ in 0..<8 {
            for side in 0..<2 where active[side] {
                let edge = edges[side]
                let candidates: [Int] = lines.indices.filter { candidate -> Bool in
                    guard !included.contains(candidate), let rect = lines[candidate].boundingBox,
                          let edgeRect = lines[edge].boundingBox,
                          side == 0 ? rect.midY > edgeRect.midY : rect.midY < edgeRect.midY else { return false }
                    let scale = CGAffineTransform(scaleX: imageSize.width, y: imageSize.height)
                    let first: CGRect = edgeRect.applying(scale)
                    let second: CGRect = rect.applying(scale)
                    let height: CGFloat = max(first.height, second.height)
                    let width: CGFloat = min(first.width, second.width)
                    let overlap: CGFloat = max(0, min(first.maxX, second.maxX) - max(first.minX, second.minX))
                    let separated = abs(first.midY - second.midY) > height * 0.6
                    let aligned = abs(first.minX - second.minX) < height * 3
                    return separated && aligned && overlap >= width * 0.6
                }
                let edgeY: CGFloat = lines[edge].boundingBox?.midY ?? 0
                let closest = candidates.min { first, second in
                    let firstDistance: CGFloat = abs((lines[first].boundingBox?.midY ?? 0) - edgeY)
                    let secondDistance: CGFloat = abs((lines[second].boundingBox?.midY ?? 0) - edgeY)
                    return firstDistance < secondDistance
                }
                guard let next = closest, continuous(lines[edge], lines[next], imageSize: imageSize, pitch: pitch),
                    lines[next].text.utf16.count + 1 <= budget else { active[side] = false; continue }
                // Inspect the closest row before testing continuity. Filtering out a heading or
                // list item first could otherwise jump over it and splice two unrelated blocks.
                if side == 0 { included.insert(next, at: 0) } else { included.append(next) }
                budget -= lines[next].text.utf16.count + 1
                edges[side] = next
            }
        }
        return included
    }

    private static func continuous(_ first: OCRTextHygiene.OCRLine, _ second: OCRTextHygiene.OCRLine,
                                   imageSize: CGSize, pitch: CGFloat?) -> Bool {
        // Vision normalizes x and y independently. Compare physical dimensions, otherwise wide
        // screenshot crops make the horizontal alignment tolerance several times too generous.
        let scale = CGAffineTransform(scaleX: imageSize.width, y: imageSize.height)
        guard let left = first.boundingBox?.applying(scale), let right = second.boundingBox?.applying(scale),
              left.height > 0, right.height > 0 else { return false }
        let upperLine = left.midY > right.midY ? first : second
        let lowerLine = left.midY > right.midY ? second : first
        let upper = left.midY > right.midY ? left : right, lower = left.midY > right.midY ? right : left
        if LearningReadingOCRLayout.startsListItem(lowerLine.text) { return false }
        if LearningReadingContextPolicy.hasTerminator(upperLine.text), lower.minX - upper.minX > upper.height * 0.8 { return false }
        let distance = abs(left.midY - right.midY)
        if let pitch, distance > pitch * 1.45 { return false }
        if pitch == nil, upper.minY - lower.maxY > min(upper.height, lower.height) * 0.85,
           upperLine.text.count < 40 { return false }
        // A wrapped list item hangs under its text, to the right of its bullet. A new unindented
        // block below a bullet must not inherit that item's label as contextual prose.
        if LearningReadingOCRLayout.startsListItem(upperLine.text), lower.minX - upper.minX < upper.height * 0.3 { return false }
        let height = max(left.height, right.height)
        let overlap = max(0, min(left.maxX, right.maxX) - max(left.minX, right.minX))
        let smallerHeight = min(left.height, right.height)
        let ratio = height / smallerHeight
        // Vision can inflate an entire row's glyph envelope on one crop (especially descenders).
        // Relax height only for almost touching, equally wide, tightly aligned wrapped rows;
        // a differently sized heading without that spatial evidence still stops the block.
        let envelopeVariation = ratio < 1.8 && upper.minY - lower.maxY < smallerHeight * 0.25 &&
            abs(left.minX - right.minX) < smallerHeight * 0.5 &&
            min(left.width, right.width) > max(left.width, right.width) * 0.8
        return (ratio < 1.6 || envelopeVariation) &&
            abs(left.midY - right.midY) > height * 0.6 &&
            abs(left.midY - right.midY) < min(left.height, right.height) * 2.2 &&
            abs(left.minX - right.minX) < height * 2 && overlap >= min(left.width, right.width) * 0.65
    }

    /// Estimate local baseline pitch from similarly sized rows in this column. The lower median
    /// excludes paragraph gaps without imposing one fixed line-height ratio on every host/font.
    private static func typicalPitch(_ lines: [OCRTextHygiene.OCRLine], index: Int, imageSize: CGSize) -> CGFloat? {
        let scale = CGAffineTransform(scaleX: imageSize.width, y: imageSize.height)
        guard let reference = lines[index].boundingBox?.applying(scale) else { return nil }
        // Named, typed stages keep these geometry predicates tractable for older Swift solvers.
        let transformed: [CGRect] = lines.compactMap { $0.boundingBox?.applying(scale) }
        let matching: [CGRect] = transformed.filter { box in
            let smallerHeight: CGFloat = min(box.height, reference.height)
            let largerHeight: CGFloat = max(box.height, reference.height)
            let similarHeight = smallerHeight > 0 && largerHeight < smallerHeight * 1.4
            let sameColumn = abs(box.minX - reference.minX) < reference.height * 2
            let nearby = abs(box.midY - reference.midY) < reference.height * 12
            return similarHeight && sameColumn && nearby
        }
        let boxes: [CGRect] = matching.sorted { $0.midY > $1.midY }
        var pitches: [CGFloat] = []
        for (first, second) in zip(boxes, boxes.dropFirst()) {
            let distance: CGFloat = first.midY - second.midY
            let lowerBound: CGFloat = max(first.height, second.height) * 0.8
            let upperBound: CGFloat = min(first.height, second.height) * 3
            if distance > lowerBound && distance < upperBound { pitches.append(distance) }
        }
        pitches.sort()
        guard pitches.count >= 2 else { return nil }
        return pitches[(pitches.count - 1) / 2]
    }
}
