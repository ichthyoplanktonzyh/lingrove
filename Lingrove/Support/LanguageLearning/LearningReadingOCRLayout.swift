import CoreGraphics
import Foundation

/// Local OCR fragments become rows before the context policy walks vertically. Each row retains
/// a map back to its original line ranges; joining a coloured link cannot relocate a repeated word.
/// These values live only for one recognition pass and never enter a model or the notebook.
nonisolated enum LearningReadingOCRLayout {
    struct Row {
        let line: OCRTextHygiene.OCRLine
        let sources: [Int: NSRange]
    }

    static func rows(_ lines: [OCRTextHygiene.OCRLine], imageSize: CGSize) -> [Row] {
        let scale = CGAffineTransform(scaleX: imageSize.width, y: imageSize.height)
        var unused = Set(lines.indices), result: [Row] = []
        for seed in lines.indices where unused.remove(seed) != nil {
            var indices = [seed]
            for _ in 0..<16 {
                guard let first = indices.first, let last = indices.last else { break }
                let neighbours = unused.filter { index in
                    joins(lines[index], lines[first], scale: scale) || joins(lines[last], lines[index], scale: scale)
                }.sorted { (lines[$0].boundingBox?.minX ?? 0) < (lines[$1].boundingBox?.minX ?? 0) }
                guard let next = neighbours.first else { break }
                indices.append(next); unused.remove(next)
                indices.sort { (lines[$0].boundingBox?.minX ?? 0) < (lines[$1].boundingBox?.minX ?? 0) }
            }
            // Mixed direction fragments are intentionally left separate by joins(). For a
            // uniformly RTL row, logical string order starts at the rightmost visual fragment.
            if rightToLeft(lines[seed].text) { indices.reverse() }
            var text = "", sources: [Int: NSRange] = [:], box = CGRect.null
            for index in indices {
                text += separator(text, lines[index].text)
                sources[index] = NSRange(location: text.utf16.count, length: lines[index].text.utf16.count)
                text += lines[index].text
                if let rect = lines[index].boundingBox { box = box.union(rect) }
            }
            result.append(.init(line: .init(text: text, confidence: indices.map { lines[$0].confidence }.min() ?? 0,
                boundingBox: box.isNull ? nil : box), sources: sources))
        }
        return result
    }

    private static func joins(_ left: OCRTextHygiene.OCRLine, _ right: OCRTextHygiene.OCRLine,
                              scale: CGAffineTransform) -> Bool {
        guard let first = left.boundingBox?.applying(scale), let second = right.boundingBox?.applying(scale),
              first.height > 0, second.height > 0, rightToLeft(left.text) == rightToLeft(right.text) else { return false }
        let height = min(first.height, second.height)
        let overlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
        let gap = second.minX - first.maxX
        return overlap >= height * 0.65 && max(first.height, second.height) < height * 1.6 &&
            gap >= 0 && gap <= height * 0.9
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
