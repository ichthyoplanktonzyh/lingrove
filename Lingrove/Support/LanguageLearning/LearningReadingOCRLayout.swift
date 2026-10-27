import CoreGraphics
import Foundation

/// Local OCR fragments become rows before the context policy walks vertically. Each row retains
/// a map back to its original line ranges; joining a coloured link cannot relocate a repeated word.
/// These values live only for one recognition pass and never enter a model or the notebook.
nonisolated enum LearningReadingOCRLayout {
    struct Row {
        let line: OCRTextHygiene.OCRLine
        let sources: [Int: Source]
    }
    /// A row may contain only one column slice of a raw Vision line. Both coordinate spaces
    /// remain explicit; an original line index alone no longer identifies the target fragment.
    struct Source {
        let original: NSRange
        let row: NSRange
    }

    static func rows(_ original: [OCRTextHygiene.OCRLine], imageSize: CGSize, words: [ScreenTextWord] = []) -> [Row] {
        let scale = CGAffineTransform(scaleX: imageSize.width, y: imageSize.height)
        let split = LearningReadingOCRColumns.split(original, words: words, imageSize: imageSize)
        let lines = split.fragments.map(\.line)
        guard let observedCuts = columnCuts(lines, scale: scale) else { return [] }
        let cuts = observedCuts + split.cuts.map { $0.applying(scale) }
        var unused = Set(lines.indices), result: [Row] = []
        for seed in lines.indices where unused.remove(seed) != nil {
            var indices = [seed]
            for _ in 0..<16 {
                guard let first = indices.first, let last = indices.last else { break }
                let neighbours = unused.filter { index in
                    joins(lines[index], lines[first], scale: scale, cuts: cuts) ||
                        joins(lines[last], lines[index], scale: scale, cuts: cuts)
                }.sorted {
                    let left = lines[$0].boundingBox?.minX ?? 0, right = lines[$1].boundingBox?.minX ?? 0
                    return left == right ? $0 < $1 : left < right
                }
                guard let next = neighbours.first else { break }
                indices.append(next); unused.remove(next)
                indices.sort { (lines[$0].boundingBox?.minX ?? 0) < (lines[$1].boundingBox?.minX ?? 0) }
            }
            // Mixed direction fragments are intentionally left separate by joins(). For a
            // uniformly RTL row, logical string order starts at the rightmost visual fragment.
            if rightToLeft(lines[seed].text) { indices.reverse() }
            var text = "", sources: [Int: Source] = [:], box = CGRect.null
            for index in indices {
                text += separator(text, lines[index].text)
                let fragment = split.fragments[index]
                sources[fragment.sourceIndex] = Source(original: fragment.sourceRange,
                    row: NSRange(location: text.utf16.count, length: lines[index].text.utf16.count))
                text += lines[index].text
                if let rect = lines[index].boundingBox { box = box.union(rect) }
            }
            result.append(.init(line: .init(text: text, confidence: indices.map { lines[$0].confidence }.min() ?? 0,
                boundingBox: box.isNull ? nil : box), sources: sources))
        }
        return result
    }

    private static func joins(_ left: OCRTextHygiene.OCRLine, _ right: OCRTextHygiene.OCRLine,
                              scale: CGAffineTransform, cuts: [CGRect]) -> Bool {
        guard let first = left.boundingBox?.applying(scale), let second = right.boundingBox?.applying(scale),
              first.height > 0, second.height > 0, rightToLeft(left.text) == rightToLeft(right.text) else { return false }
        let height = min(first.height, second.height)
        let overlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
        let gap = second.minX - first.maxX
        // A bold/link fragment may be taller while sharing the same baseline. Repeated gutters
        // on other rows, however, are column evidence even when their gap resembles word spacing.
        return overlap >= height * 0.65 && max(first.height, second.height) < height * 2 &&
            abs(first.minY - second.minY) <= height * 0.3 && gap >= 0 && gap <= height * 0.9 &&
            !cuts.contains { first.maxX <= $0.midX && second.minX >= $0.midX &&
                first.midY >= $0.minY && first.midY <= $0.maxY }
    }

    /// Two independent rows must corroborate a narrow gutter. A single link gap is insufficient
    /// to split a row. Only gaps that the ordinary same-row rule could join need this extra work.
    private static func columnCuts(_ lines: [OCRTextHygiene.OCRLine], scale: CGAffineTransform) -> [CGRect]? {
        let boxes = lines.compactMap { $0.boundingBox?.applying(scale) }.filter { $0.width > 0 && $0.height > 0 }
        // A gap's rectangle retains its horizontal interval and corroborating row baseline.
        var gaps: [CGRect] = []
        for first in boxes {
            for second in boxes where second.minX >= first.maxX {
                let height = min(first.height, second.height), gap = second.minX - first.maxX
                let overlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
                if gap >= height * 0.5, gap <= height * 0.9, overlap >= height * 0.65,
                   max(first.height, second.height) < height * 1.6 {
                    gaps.append(CGRect(x: first.maxX, y: first.midY - height / 2, width: gap, height: height))
                    guard gaps.count <= 2_048 else { return nil }
                }
            }
        }
        return gaps.compactMap { gap in
            guard let other = gaps.first(where: {
                abs($0.midY - gap.midY) > max($0.height, gap.height) &&
                    abs($0.midY - gap.midY) <= max($0.height, gap.height) * 4 &&
                    max($0.minX, gap.minX) < min($0.maxX, gap.maxX)
            }) else { return nil }
            let band = gap.union(other)
            return CGRect(x: (max(other.minX, gap.minX) + min(other.maxX, gap.maxX)) / 2,
                y: band.minY, width: 0, height: band.height)
        }
    }

    static func startsListItem(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:[•●▪‣*−-]|\d+[.)])\s+"#, options: .regularExpression) != nil
    }

    private static func rightToLeft(_ text: String) -> Bool {
        guard let first = text.first(where: \.isLetter) else { return false }
        return String(first).range(of: #"[\p{Arabic}\p{Hebrew}]"#, options: .regularExpression) != nil
    }

    static func separator(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first,
              !last.isWhitespace, !first.isWhitespace, last != "-" else { return "" }
        let cjk = #"^[\p{Han}\p{Hiragana}\p{Katakana}，。！？、」』]$"#
        if String(last).range(of: cjk, options: .regularExpression) != nil &&
            String(first).range(of: cjk, options: .regularExpression) != nil { return "" }
        return " "
    }
}
