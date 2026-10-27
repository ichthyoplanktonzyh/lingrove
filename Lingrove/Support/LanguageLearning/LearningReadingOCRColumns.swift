import CoreGraphics
import Foundation

/// Recovers repeated side-by-side UI columns even when Vision emitted them as one text line.
/// Three equal words aligned on distinct baselines corroborate a boundary; text alone never
/// supplies one. Layout borrows these fragments for one frame, retaining each original UTF-16
/// range so splitting a merged row cannot relocate a repeated target or rewrite its spelling.
nonisolated enum LearningReadingOCRColumns {
    struct Fragment {
        let line: OCRTextHygiene.OCRLine
        let sourceIndex: Int
        let sourceRange: NSRange
    }
    private struct Anchor {
        let word: ScreenTextWord
        let previous: ScreenTextWord
        let line: Int
    }

    static func split(_ lines: [OCRTextHygiene.OCRLine], words: [ScreenTextWord], imageSize: CGSize)
        -> (fragments: [Fragment], cuts: [CGRect]) {
        let valid = words.filter { word in
            guard let index = word.lineIndex, lines.indices.contains(index),
                  let offset = word.utf16Location, let length = word.utf16Length else { return false }
            let range = NSRange(location: offset, length: length)
            return VocabularyPolicy.valid(range, in: lines[index].text) &&
                (lines[index].text as NSString).substring(with: range) == word.text
        }
        let grouped = Dictionary(grouping: valid, by: { $0.lineIndex ?? -1 }).mapValues {
            $0.sorted { ($0.utf16Location ?? 0) < ($1.utf16Location ?? 0) }
        }
        let cuts = repeatedCuts(grouped, imageSize: imageSize)
        var fragments: [Fragment] = []
        for (index, line) in lines.enumerated() {
            let lineWords = grouped[index] ?? []
            var offsets = [0]
            for cut in cuts where line.boundingBox.map({ $0.maxY >= cut.minY && $0.minY <= cut.maxY }) ?? false {
                if let next = lineWords.indices.dropFirst().first(where: {
                    lineWords[$0 - 1].boundingBox.maxX <= cut.midX && lineWords[$0].boundingBox.minX >= cut.midX
                }), let offset = lineWords[next].utf16Location { offsets.append(offset) }
            }
            offsets.append(line.text.utf16.count)
            offsets = Array(Set(offsets)).sorted()
            if offsets.count == 2 {
                fragments.append(.init(line: line, sourceIndex: index,
                    sourceRange: NSRange(location: 0, length: line.text.utf16.count)))
                continue
            }
            for (lower, upper) in zip(offsets, offsets.dropFirst()) {
                let raw = (line.text as NSString).substring(with: NSRange(location: lower, length: upper - lower))
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let start = lower + raw.prefix(while: \.isWhitespace).utf16.count
                let range = NSRange(location: start, length: trimmed.utf16.count)
                let boxes = lineWords.filter {
                    NSIntersectionRange(range, NSRange(location: $0.utf16Location ?? 0, length: $0.utf16Length ?? 0)).length > 0
                }.map(\.boundingBox)
                let box = boxes.reduce(CGRect.null) { $0.union($1) }
                // Split pieces use only their own words, not the neighbouring column's box.
                let bounds = box.isNull ? line.boundingBox : box
                fragments.append(.init(line: .init(text: trimmed, confidence: line.confidence, boundingBox: bounds),
                    sourceIndex: index, sourceRange: range))
            }
        }
        return (fragments, cuts)
    }

    private static func repeatedCuts(_ grouped: [Int: [ScreenTextWord]], imageSize: CGSize) -> [CGRect] {
        var anchors: [String: [Anchor]] = [:]
        for (line, words) in grouped where words.count >= 5 {
            for index in 2..<(words.count - 2) {
                let phrase = words[index..<(index + 3)].map(\.text).joined(separator: " ")
                guard phrase.filter(\.isLetter).count >= 12,
                      words[index - 1].boundingBox.maxX < words[index].boundingBox.minX else { continue }
                anchors[phrase, default: []].append(.init(word: words[index], previous: words[index - 1], line: line))
            }
        }
        var cuts: [CGRect] = []
        for group in anchors.values where (2...128).contains(group.count) {
            for anchor in group {
                let box = anchor.word.boundingBox
                let matching = group.first { other in
                    let otherBox = other.word.boundingBox
                    return other.line != anchor.line && other.previous.text != anchor.previous.text &&
                        abs(otherBox.midY - box.midY) > max(otherBox.height, box.height) * 0.8 &&
                        abs(otherBox.midY - box.midY) <= max(otherBox.height, box.height) * 4 &&
                        abs(otherBox.minX - box.minX) * imageSize.width <= max(3, min(otherBox.height, box.height) * imageSize.height * 0.3)
                }
                if let matching {
                    let left = max(anchor.previous.boundingBox.maxX, matching.previous.boundingBox.maxX)
                    let right = min(box.minX, matching.word.boundingBox.minX)
                    if left < right {
                        // A repeated sidebar says nothing about a full-width paragraph elsewhere
                        // on the page. Keep the gutter local to its corroborating baselines.
                        let band = box.union(matching.word.boundingBox)
                        cuts.append(CGRect(x: (left + right) / 2, y: band.minY,
                            width: 0, height: band.height))
                    }
                }
            }
        }
        return cuts.sorted { $0.midX == $1.midX ? $0.minY < $1.minY : $0.midX < $1.midX }
    }
}
