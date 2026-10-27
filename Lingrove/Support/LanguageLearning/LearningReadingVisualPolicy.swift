import CoreGraphics
import Foundation

/// Pure geometry for one frozen reading frame. Capture and OCR use different origins, so all
/// conversions live here; callers never combine a word box with a later screen or mouse position.
nonisolated enum LearningReadingVisualPolicy {
    private struct HitCandidate {
        let word: ScreenTextWord
        let distance: CGFloat
        let ambiguityMargin: CGFloat
    }

    static let initialSize = CGSize(width: 720, height: 240)

    static func snapshotBounds(at point: CGPoint, screen: CGRect, window: CGRect?, scale: CGFloat) -> CGRect? {
        guard scale.isFinite, scale > 0, screen.contains(point) else { return nil }
        guard let window else { return nil }
        let visible = screen.intersection(window)
        guard visible.contains(point), visible.width >= 4, visible.height >= 4 else { return nil }
        // Preserve glyph resolution. A large desktop is cropped, never downsampled to make a
        // small word unreadable. Even high-density displays stay below the capture pixel limit.
        let factor = min(1, sqrt(16_000_000 / (1_600 * 1_200 * scale * scale)))
        return centered(at: point, size: CGSize(width: 1_600 * factor, height: 1_200 * factor), within: visible)
    }

    static func centered(at point: CGPoint, size: CGSize, within bounds: CGRect) -> CGRect {
        let width = min(size.width, bounds.width), height = min(size.height, bounds.height)
        return CGRect(x: min(max(point.x - width / 2, bounds.minX), bounds.maxX - width),
            y: min(max(point.y - height / 2, bounds.minY), bounds.maxY - height), width: width, height: height)
    }

    /// Expand along the axis reached by the text block. OCR may drop a clipped leading word,
    /// leaving false whitespace at the opposite edge, so preserve a side only with a proven
    /// sentence boundary. The untouched axis stays local; no second frame is captured.
    static func expanded(_ region: CGRect, toward text: CGRect?, context: LearningReadingContext? = nil,
                         within bounds: CGRect) -> CGRect {
        guard let text else { return bounds }
        let inner = region.insetBy(dx: 28, dy: 28)
        let horizontal = text.minX <= inner.minX || text.maxX >= inner.maxX
        let vertical = text.minY <= inner.minY || text.maxY >= inner.maxY
        let left = horizontal && context?.left.isComplete != true ? bounds.minX : region.minX
        let right = horizontal && context?.right.isComplete != true ? bounds.maxX : region.maxX
        let bottom = vertical && context?.right.isComplete != true ? bounds.minY : region.minY
        let top = vertical && context?.left.isComplete != true ? bounds.maxY : region.maxY
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom).intersection(bounds)
    }

    /// CGImage cropping uses top-left pixel coordinates. Expand to whole pixels and return the
    /// corresponding screen rectangle too, so rounding never silently moves the hit-test origin.
    static func crop(_ region: CGRect, frame: CGRect, pixels: CGSize) -> (pixels: CGRect, screen: CGRect) {
        let scaleX = pixels.width / frame.width, scaleY = pixels.height / frame.height
        let rect = CGRect(x: (region.minX - frame.minX) * scaleX, y: (frame.maxY - region.maxY) * scaleY,
            width: region.width * scaleX, height: region.height * scaleY).integral
            .intersection(CGRect(origin: .zero, size: pixels))
        return (rect, CGRect(x: frame.minX + rect.minX / scaleX, y: frame.maxY - rect.maxY / scaleY,
            width: rect.width / scaleX, height: rect.height / scaleY))
    }

    static func screenRect(_ box: CGRect, in region: CGRect) -> CGRect {
        CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
            width: box.width * region.width, height: box.height * region.height)
    }

    /// Exact, validated hits win. A small glyph-height-relative tolerance helps near an edge;
    /// equally plausible neighbours remain ambiguous instead of depending on OCR array order.
    static func hit(at point: CGPoint, in result: ExtractedScreenText, pixels: CGSize) -> ScreenTextWord? {
        let transform = CGAffineTransform(scaleX: pixels.width, y: pixels.height)
        let point = point.applying(transform)
        let candidates = result.words.compactMap { word -> HitCandidate? in
            guard let index = word.lineIndex, result.lines.indices.contains(index),
                  let offset = word.utf16Location, let length = word.utf16Length,
                  word.text.contains(where: \.isLetter),
                  word.confidence.map({ $0.isFinite && $0 >= 0.3 }) ?? true else { return nil }
            let range = NSRange(location: offset, length: length), line = result.lines[index]
            guard VocabularyPolicy.valid(range, in: line.text),
                  (line.text as NSString).substring(with: range).utf16.elementsEqual(word.text.utf16),
                  line.boundingBox?.intersects(word.boundingBox) == true else { return nil }
            let box = word.boundingBox.applying(transform)
            guard box.width > 0, box.height > 0 else { return nil }
            let tolerance = min(8, box.height * 0.22)
            let dx = max(box.minX - point.x, point.x - box.maxX, 0)
            let dy = max(box.minY - point.y, point.y - box.maxY, 0)
            let distance = hypot(dx, dy)
            guard distance <= tolerance else { return nil }
            return HitCandidate(word: word, distance: distance, ambiguityMargin: min(2, box.height * 0.08))
        }.sorted { $0.distance < $1.distance }
        guard let first = candidates.first else { return nil }
        if candidates.count > 1, candidates[1].distance - first.distance <= first.ambiguityMargin {
            return compound(candidates.filter { $0.distance - first.distance <= first.ambiguityMargin }.map(\.word), lines: result.lines)
        }
        return first.word
    }

    /// Vision sometimes gives every subtoken/character of a hyphenated word the same full word
    /// box. Geometry cannot select one subtoken truthfully. Keep the indivisible printed unit;
    /// unrelated overlapping words and whitespace-separated phrases remain ambiguous.
    private static func compound(_ words: [ScreenTextWord], lines: [OCRTextHygiene.OCRLine]) -> ScreenTextWord? {
        guard (2...8).contains(words.count), let first = words.first, let index = first.lineIndex,
              lines.indices.contains(index), words.allSatisfy({ $0.lineIndex == index && $0.boundingBox == first.boundingBox })
        else { return nil }
        let ordered = words.sorted { ($0.utf16Location ?? 0) < ($1.utf16Location ?? 0) }
        let line = lines[index].text as NSString
        for pair in zip(ordered, ordered.dropFirst()) {
            guard let start = pair.0.utf16Location, let length = pair.0.utf16Length, let next = pair.1.utf16Location,
                  next > start + length else { return nil }
            let join = line.substring(with: NSRange(location: start + length, length: next - start - length))
            guard join.range(of: #"^[-‐‑'’]+$"#, options: .regularExpression) != nil else { return nil }
        }
        guard let start = ordered.first?.utf16Location, let last = ordered.last,
              let end = last.utf16Location, let length = last.utf16Length, end + length - start <= 64 else { return nil }
        let range = NSRange(location: start, length: end + length - start)
        return ScreenTextWord(text: line.substring(with: range), boundingBox: first.boundingBox, lineIndex: index,
            utf16Location: range.location, utf16Length: range.length, confidence: words.compactMap(\.confidence).min())
    }
}
