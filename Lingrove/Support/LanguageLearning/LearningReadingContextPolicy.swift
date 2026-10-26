import Foundation
import NaturalLanguage

/// Validates occurrence identity, derives sentence boundaries and compares acquisition candidates.
/// AX and OCR share these rules; neither adapter may promote an arbitrary node/line to a sentence.
nonisolated enum LearningReadingContextPolicy {
    static let maximumSelectionUTF16 = 3_072
    static let surroundingUTF16 = 512
    static let maximumSurroundingUTF16 = surroundingUTF16 * 2

    static func resolve(_ window: LearningReadingWindow, expected: String) -> LearningReadingContext? {
        guard VocabularyPolicy.valid(window.target, in: window.text),
              window.text.utf16.count - window.target.length <= maximumSurroundingUTF16 else { return nil }
        let window = trimmingArtificialEdges(window)
        let text = window.text as NSString, range = window.target
        guard !expected.isEmpty, expected.utf16.count <= maximumSelectionUTF16,
              range.length == expected.utf16.count, VocabularyPolicy.valid(range, in: window.text),
              text.substring(with: range).utf16.elementsEqual(expected.utf16),
              text.length - range.length <= maximumSurroundingUTF16 else { return nil }
        let leading = expected.prefix(while: \.isWhitespace).utf16.count
        let trimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = NSRange(location: range.location + leading, length: trimmed.utf16.count)
        guard !trimmed.isEmpty, VocabularyPolicy.valid(target, in: window.text) else { return nil }
        if window.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed,
           !trimmed.contains(where: \.isWhitespace), !hasTerminator(trimmed) { return nil }

        // Use the same bounded language evidence throughout reading. Leaving the tokenizer's
        // language unset is preferable to substituting English for unknown or mixed prose.
        let hint = LearningLanguage.detect(in: window.text)
        let tokenizer = NLTokenizer(unit: .sentence)
        if let hint { tokenizer.setLanguage(hint.naturalLanguage) }
        tokenizer.string = window.text
        var sentences: [NSRange] = []
        tokenizer.enumerateTokens(in: window.text.startIndex..<window.text.endIndex) { token, _ in
            let token = NSRange(token, in: window.text)
            if NSIntersectionRange(token, target).length > 0 { sentences.append(token) }
            return true
        }
        guard let first = sentences.first, let last = sentences.last else { return nil }
        let scope = NSRange(location: min(first.location, target.location),
            length: max(NSMaxRange(last), NSMaxRange(target)) - min(first.location, target.location))
        let prefix = text.substring(to: scope.location)
        let suffix = text.substring(from: NSMaxRange(scope))
        // Whitespace before a tokenizer token is not a preceding sentence. This distinction is
        // essential for a crop such as " while preserving your review history.".
        let left: LearningReadingWindow.Boundary = hasTerminator(prefix) ? .sentence
            : prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? window.left : .unknown
        let scoped = text.substring(with: scope)
        let right: LearningReadingWindow.Boundary = hasTerminator(scoped) &&
            (!suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || window.right.isComplete) ? .sentence
            : suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? window.right : .unknown
        return .init(window: window, scope: scope,
            target: NSRange(location: target.location - scope.location, length: target.length),
            left: left, right: right, sentenceCount: sentences.count, languageHint: hint)
    }

    /// Compare verified coverage, not API order or raw string length. A whole sentence wins;
    /// otherwise retain the most informative bounded fragment instead of discarding all evidence.
    static func best(_ candidates: [LearningReadingWindow], expected: String) -> LearningReadingContext? {
        candidates.compactMap { resolve($0, expected: expected) }.max { lhs, rhs in
            if lhs.isComplete != rhs.isComplete { return !lhs.isComplete }
            let leftProof = (lhs.left.isComplete ? 1 : 0) + (lhs.right.isComplete ? 1 : 0)
            let rightProof = (rhs.left.isComplete ? 1 : 0) + (rhs.right.isComplete ? 1 : 0)
            if leftProof != rightProof { return leftProof < rightProof }
            if lhs.isComplete { return lhs.text.utf16.count > rhs.text.utf16.count }
            return lhs.text.utf16.count < rhs.text.utf16.count
        }
    }

    /// Reallocate the unused half near a container edge. A word at the end of a long sentence
    /// can use the entire surrounding budget on its left without increasing total acquisition.
    static func windowRange(target: NSRange, count: Int) -> NSRange? {
        guard target.location >= 0, target.length > 0, target.length <= maximumSelectionUTF16,
              target.location <= count, target.length <= count - target.location else { return nil }
        var before = min(surroundingUTF16, target.location)
        let after = min(maximumSurroundingUTF16 - before, count - NSMaxRange(target))
        before = min(maximumSurroundingUTF16 - after, target.location)
        return NSRange(location: target.location - before, length: before + target.length + after)
    }

    static func hasTerminator(_ text: String) -> Bool {
        text.range(of: #"[.!?。！？…][\"'”’»）」』】\]\)]*\s*$"#, options: .regularExpression) != nil
    }

    /// AX windows are requested in UTF-16 units. A cropped outer grapheme can be a detached
    /// combining mark or half of a surrogate pair after bridging. Discard that outer cluster,
    /// only outside the target, rather than sending potentially damaged context to the model.
    /// OCR lines already contain complete recognized strings and must not lose edge characters.
    private static func trimmingArtificialEdges(_ window: LearningReadingWindow) -> LearningReadingWindow {
        guard window.method == .characters || window.method == .markerWalk,
              VocabularyPolicy.valid(window.target, in: window.text) else { return window }
        let text = window.text as NSString
        var lower = 0, upper = text.length
        if window.left == .crop, let first = window.text.first {
            let length = String(first).utf16.count
            if length <= window.target.location { lower = length }
        }
        if window.right == .crop, let last = window.text.last {
            let length = String(last).utf16.count
            if text.length - length >= NSMaxRange(window.target) { upper -= length }
        }
        return .init(text: text.substring(with: NSRange(location: lower, length: upper - lower)),
            target: NSRange(location: window.target.location - lower, length: window.target.length),
            left: window.left, right: window.right, method: window.method, confidence: window.confidence)
    }
}
