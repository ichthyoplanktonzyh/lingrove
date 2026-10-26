import CoreGraphics
import Foundation

/// Aligns one explicit AX selection with a bounded OCR block. Text and geometry must identify
/// one occurrence; AX remains authoritative for the selected UTF-16 code units. Normalization
/// exists only for alignment and never rewrites the surrounding recognized original.
nonisolated enum LearningReadingSelectionOCRPolicy {
    struct Match {
        let context: LearningReadingContext
        let bounds: CGRect
        let targetBounds: CGRect
    }
    enum Unavailable: String { case invalidGeometry, budgetExceeded, noSpatialWords, noContextBlock, noAlignedOccurrence }
    enum Alignment { case matched(Match), ambiguous, unavailable(Unavailable) }

    private struct Candidate {
        let match: Match
        let occurrence: String
    }

    static func match(_ selection: LearningReadingSelection, extraction: ExtractedScreenText,
                      region: CGRect, pixels: CGSize) -> Match? {
        if case .matched(let match) = alignment(selection, extraction: extraction, region: region, pixels: pixels) { return match }
        return nil
    }

    static func alignment(_ selection: LearningReadingSelection, extraction: ExtractedScreenText,
                          region: CGRect, pixels: CGSize) -> Alignment {
        guard let bounds = selection.selectionBounds, valid(bounds), region.contains(bounds) else { return .unavailable(.invalidGeometry) }
        guard selection.text.utf16.count <= LearningReadingContextPolicy.maximumSelectionUTF16,
              extraction.words.count <= 16_384 else { return .unavailable(.budgetExceeded) }
        var occurrences: [String: Match] = [:], visited = Set<Int>()
        var blockCount = 0
        let seeds = extraction.words.filter {
            LearningReadingVisualPolicy.screenRect($0.boundingBox, in: region).intersects(bounds)
        }
        guard !seeds.isEmpty else { return .unavailable(.noSpatialWords) }
        // Silently truncating seeds could hide a second plausible occurrence. Keep the work
        // bounded, but reject the alignment if we cannot inspect all spatial candidates.
        guard seeds.count <= 64 else { return .unavailable(.budgetExceeded) }
        for word in seeds {
            guard let index = word.lineIndex, visited.insert(index).inserted,
                  let block = LearningReadingOCRPolicy.block(word: word, lines: extraction.lines, imageSize: pixels),
                  let window = block.context?.window, (window.confidence ?? 1) >= 0.5 else { continue }
            blockCount += 1
            for candidate in candidates(selection, block: block, window: window, extraction: extraction, region: region) {
                let previous = occurrences[candidate.occurrence]
                if previous == nil || candidate.match.context.text.utf16.count > (previous?.context.text.utf16.count ?? 0) {
                    occurrences[candidate.occurrence] = candidate.match
                }
            }
        }
        if occurrences.count > 1 { return .ambiguous }
        guard let match = occurrences.values.first else {
            return .unavailable(blockCount == 0 ? .noContextBlock : .noAlignedOccurrence)
        }
        return .matched(match)
    }

    /// Exact AX context wins ties. OCR must preserve the known adjacent AX text (ignoring only
    /// whitespace/NFC differences such as an AX link seam) and supply genuinely better coverage.
    static func preferred(ax: LearningReadingContext?, visual: LearningReadingContext?, expected: String) -> LearningReadingContext? {
        guard let visual, validTarget(visual, expected: expected) else { return ax }
        guard let ax else { return visual }
        guard !ax.isComplete, validTarget(ax, expected: expected), compatible(ax, visual) else { return ax }
        if visual.isComplete { return visual }
        return visual.text.utf16.count > ax.text.utf16.count ? visual : ax
    }

    static func valid(_ bounds: CGRect) -> Bool {
        bounds.minX.isFinite && bounds.minY.isFinite && bounds.width.isFinite && bounds.height.isFinite &&
            bounds.width > 1 && bounds.height > 1
    }

    private static func candidates(_ selection: LearningReadingSelection, block: LearningReadingOCRPolicy.Block,
                                   window: LearningReadingWindow, extraction: ExtractedScreenText, region: CGRect) -> [Candidate] {
        let canonical = Canonical(window.text)
        let target = Canonical(selection.text).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, let selectionBounds = selection.selectionBounds else { return [] }
        let exact = canonical.occurrences(of: target).compactMap { range in
            candidate(selection, range: range, block: block, extraction: extraction, region: region)
        }
        guard exact.isEmpty, target.utf16.count <= 64, target.allSatisfy(\.isLetter),
              let ax = selection.context, validTarget(ax, expected: selection.text), hasNeighbourEvidence(ax) else { return exact }
        // Highlight colours can corrupt the OCR spelling of precisely the word AX already
        // supplies. Recover only a spatially verified word with matching AX text on its sides;
        // this is occurrence alignment, never a spelling guess or a fuzzy page-wide search.
        return extraction.words.compactMap { word in
            guard agrees(LearningReadingVisualPolicy.screenRect(word.boundingBox, in: region), selectionBounds),
                  word.text.allSatisfy({ $0.isLetter || $0.isNumber }),
                  let line = word.lineIndex, let offset = word.utf16Location, let length = word.utf16Length,
                  extraction.lines.indices.contains(line), length > 0, length <= 64,
                  VocabularyPolicy.valid(NSRange(location: offset, length: length), in: extraction.lines[line].text),
                  (extraction.lines[line].text as NSString).substring(with: NSRange(location: offset, length: length))
                    .utf16.elementsEqual(word.text.utf16),
                  let source = block.sources.first(where: {
                      $0.lineIndex == line && offset >= $0.sourceRange.location && offset + length <= NSMaxRange($0.sourceRange)
                  }) else { return nil }
            let range = NSRange(location: source.windowRange.location + offset - source.sourceRange.location, length: length)
            guard VocabularyPolicy.valid(range, in: window.text),
                  (window.text as NSString).substring(with: range).utf16.elementsEqual(word.text.utf16) else { return nil }
            return candidate(selection, range: range, block: block, extraction: extraction,
                region: region, requiresQuote: true)
        }
    }

    private static func candidate(_ selection: LearningReadingSelection, range: NSRange,
                                  block: LearningReadingOCRPolicy.Block,
                                  extraction: ExtractedScreenText, region: CGRect, requiresQuote: Bool = false) -> Candidate? {
        guard let window = block.context?.window, let selectionBounds = selection.selectionBounds,
              VocabularyPolicy.valid(range, in: window.text) else { return nil }
        let words = overlappingWords(range, sources: block.sources, extraction: extraction)
        let box = words.map { LearningReadingVisualPolicy.screenRect($0.boundingBox, in: region) }
            .reduce(CGRect.null) { $0.union($1) }
        let text = (window.text as NSString).replacingCharacters(in: range, with: selection.text)
        let aligned = LearningReadingWindow(text: text,
            target: NSRange(location: range.location, length: selection.text.utf16.count),
            left: window.left, right: window.right, method: .selectionOCR, confidence: window.confidence,
            targetIntroducesLineBreaks: LearningReadingTargetPolicy.introducesLineBreaks(
                (window.text as NSString).substring(with: range), selection.text))
        guard let context = LearningReadingContextPolicy.resolve(aligned, expected: selection.text) else { return nil }
        if requiresQuote {
            guard agrees(box, selectionBounds), let ax = selection.context, compatible(ax, context) else { return nil }
        } else {
            guard agrees(box, selectionBounds) || corroboratedRun(box, selectionBounds, selection: selection, context: context)
            else { return nil }
        }
        let identity = block.sources.compactMap { source -> String? in
            let overlap = NSIntersectionRange(source.windowRange, range)
            guard overlap.length > 0 else { return nil }
            let offset = source.sourceRange.location + overlap.location - source.windowRange.location
            return "\(source.lineIndex):\(offset):\(overlap.length)"
        }.sorted().joined(separator: "|")
        guard !identity.isEmpty else { return nil }
        return Candidate(match: Match(context: context,
            bounds: LearningReadingVisualPolicy.screenRect(block.bounds, in: region), targetBounds: box), occurrence: identity)
    }

    private static func overlappingWords(_ range: NSRange, sources: [LearningReadingOCRPolicy.Source],
                                         extraction: ExtractedScreenText) -> [ScreenTextWord] {
        extraction.words.filter { word in
            guard let line = word.lineIndex, extraction.lines.indices.contains(line),
                  let offset = word.utf16Location, let length = word.utf16Length else { return false }
            let rawRange = NSRange(location: offset, length: length), text = extraction.lines[line].text
            guard VocabularyPolicy.valid(rawRange, in: text),
                  (text as NSString).substring(with: rawRange).utf16.elementsEqual(word.text.utf16) else { return false }
            return sources.contains { source in
                guard source.lineIndex == line else { return false }
                let visible = NSIntersectionRange(source.sourceRange, rawRange)
                guard visible.length > 0 else { return false }
                let mapped = NSRange(location: source.windowRange.location + visible.location - source.sourceRange.location,
                    length: visible.length)
                return NSIntersectionRange(range, mapped).length > 0
            }
        }
    }

    private static func agrees(_ text: CGRect, _ selection: CGRect) -> Bool {
        guard valid(text), valid(selection) else { return false }
        let intersection = text.intersection(selection.insetBy(dx: -3, dy: -3))
        let area = min(text.width * text.height, selection.width * selection.height)
        return !intersection.isNull && intersection.width * intersection.height >= area * 0.7 &&
            text.width <= selection.width * 3 + 8 && selection.width <= text.width * 1.5 + 8 &&
            text.height <= selection.height * 1.5 + 8 && selection.height <= text.height * 2 + 8
    }

    /// Chromium can return an entire static-text run's box for a short marker selection. Such
    /// a box is a search band, not a glyph box. Accept it only with exact adjacent AX text and
    /// unique OCR occurrence evidence; a whole field/page frame cannot substitute for a row.
    private static func corroboratedRun(_ text: CGRect, _ bounds: CGRect,
                                        selection: LearningReadingSelection, context: LearningReadingContext) -> Bool {
        // Vision's glyph envelope changes slightly with crop size, especially on highlighted
        // descenders. A fixed 3pt vertical pad can reject the same word by a fraction of a point.
        // Keep the pad bounded and still require exact neighbouring text and uniqueness.
        let verticalPadding = min(8, max(3, min(text.height, bounds.height) * 0.25))
        guard valid(text), let ax = selection.context, validTarget(ax, expected: selection.text), compatible(ax, context),
              bounds.insetBy(dx: -3, dy: -verticalPadding).contains(text),
              text.height <= bounds.height * 1.5 + 8,
              bounds.height <= text.height * 1.5 + 8 else { return false }
        return hasNeighbourEvidence(ax)
    }

    private static func hasNeighbourEvidence(_ context: LearningReadingContext) -> Bool {
        let raw = context.text as NSString
        let neighbours = String(raw.substring(to: context.target.location).suffix(32)) +
            String(raw.substring(from: NSMaxRange(context.target)).prefix(32))
        return neighbours.filter { !$0.isWhitespace }.count >= 8 && neighbours.contains(where: \.isLetter)
    }

    private static func validTarget(_ context: LearningReadingContext, expected: String) -> Bool {
        VocabularyPolicy.valid(context.window.target, in: context.window.text) &&
            (context.window.text as NSString).substring(with: context.window.target).utf16.elementsEqual(expected.utf16)
    }

    private static func compatible(_ ax: LearningReadingContext, _ visual: LearningReadingContext) -> Bool {
        let old = ax.text as NSString, new = visual.text as NSString
        let left = String(old.substring(to: ax.target.location).suffix(32))
        let right = String(old.substring(from: NSMaxRange(ax.target)).prefix(32))
        func compact(_ text: String) -> String {
            String(text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace })
        }
        return compact(new.substring(to: visual.target.location)).hasSuffix(compact(left)) &&
            compact(new.substring(from: NSMaxRange(visual.target))).hasPrefix(compact(right))
    }

    /// Every normalized UTF-16 unit points back to a complete original grapheme. Canonical
    /// equivalents and soft wraps can align without moving an occurrence or splitting an emoji.
    private struct Canonical {
        let text: String
        private let originals: [NSRange]
        init(_ raw: String) {
            var text = "", originals: [NSRange] = [], offset = 0
            for character in raw {
                let original = NSRange(location: offset, length: String(character).utf16.count)
                offset += original.length
                if character.isWhitespace, text.last == " " {
                    if let last = originals.indices.last { originals[last].length = NSMaxRange(original) - originals[last].location }
                    continue
                }
                let normalized = character.isWhitespace ? " " : String(character).precomposedStringWithCanonicalMapping
                text += normalized
                originals += Array(repeating: original, count: normalized.utf16.count)
            }
            self.text = text; self.originals = originals
        }
        func occurrences(of target: String) -> [NSRange] {
            let raw = text as NSString
            var offset = 0, result: [NSRange] = []
            while offset < raw.length, result.count < 64 {
                let found = raw.range(of: target, options: .literal, range: NSRange(location: offset, length: raw.length - offset))
                guard found.location != NSNotFound, NSMaxRange(found) <= originals.count else { break }
                let first = originals[found.location], last = originals[NSMaxRange(found) - 1]
                result.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
                offset = found.location + 1
            }
            return result
        }
    }
}
