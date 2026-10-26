import Foundation

/// Reconciles two representations of an already anchored selection. This stateless adapter is
/// used only at reading boundaries; editing receipts and the strict context contract stay exact.
/// It never searches for a different occurrence or repairs spelling, case, or punctuation.
nonisolated enum LearningReadingTargetPolicy {
    static func equivalent(_ actual: String, _ expected: String) -> Bool {
        guard actual.utf16.count <= LearningReadingContextPolicy.maximumSelectionUTF16,
              expected.utf16.count <= LearningReadingContextPolicy.maximumSelectionUTF16 else { return false }
        let lhs = canonical(actual), rhs = canonical(expected)
        return !lhs.isEmpty && lhs.utf16.elementsEqual(rhs.utf16)
    }

    /// AXSelectedText and marker/range strings can differ in spaces or Unicode composition.
    /// Replace only the proven range with authoritative selected text and recompute its length;
    /// carrying the old UTF-16 length into the rewritten window would move the highlight.
    static func aligned(_ window: LearningReadingWindow, expected: String) -> LearningReadingWindow? {
        guard VocabularyPolicy.valid(window.target, in: window.text),
              window.text.utf16.count - window.target.length <= LearningReadingContextPolicy.maximumSurroundingUTF16,
              equivalent((window.text as NSString).substring(with: window.target), expected) else { return nil }
        let actual = (window.text as NSString).substring(with: window.target)
        return .init(text: (window.text as NSString).replacingCharacters(in: window.target, with: expected),
            target: NSRange(location: window.target.location, length: expected.utf16.count),
            left: window.left, right: window.right, method: window.method, confidence: window.confidence,
            targetIntroducesLineBreaks: window.targetIntroducesLineBreaks || introducesLineBreaks(actual, expected))
    }

    static func introducesLineBreaks(_ actual: String, _ expected: String) -> Bool {
        !actual.contains(where: \.isNewline) && expected.contains(where: \.isNewline)
    }

    static func selectedBlock(_ fragments: [String], expected: String, role: String) -> LearningReadingWindow? {
        // Inline leaves may split a CJK heading or a Latin word with no separator. Try the
        // literal concatenation first; inserted spaces are only an alternative representation.
        selectedBlock(fragments.joined(), expected: expected, role: role) ??
            selectedBlock(fragments.joined(separator: " "), expected: expected, role: role)
    }

    /// Whole structural material can be translated without sentence punctuation. Matching the
    /// entire heading/cell/paragraph is essential: an inline span or a partial cell proves nothing.
    static func selectedBlock(_ text: String, expected: String, role: String) -> LearningReadingWindow? {
        guard ["AXHeading", "AXCell", "AXParagraph", "AXListItem", "AXTextArea", "AXTextField"].contains(role),
              equivalent(text, expected) else { return nil }
        return .init(text: expected, target: NSRange(location: 0, length: expected.utf16.count),
            left: .layoutBlock, right: .layoutBlock, method: .block)
    }

    private static func canonical(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
