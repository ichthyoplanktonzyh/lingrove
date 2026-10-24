import Foundation

/// Shared literal-range validation for editor transactions. Unlike translation scope, an insertion
/// may be empty and a command marker may contain no letters. This helper never chooses a range or
/// silently widens one; callers remain responsible for what the user explicitly authorized.
nonisolated enum EditorTextRangePolicy {
    static func text(_ value: String, range: NSRange) throws -> String {
        let text = value as NSString
        guard range.location >= 0, range.length >= 0, range.location <= text.length,
              range.length <= text.length - range.location, Range(range, in: value) != nil,
              isWholeCharacterRange(range, in: text) else {
            throw LearningFailure.message(String(localized: "The editor text range cannot be verified. Open the preview again.",
                table: "Learning"))
        }
        return text.substring(with: range)
    }

    private static func isWholeCharacterRange(_ range: NSRange, in text: NSString) -> Bool {
        // Foundation expands an empty range in the middle of a string to the following character.
        // A caret needs only a valid boundary; comparing that expansion to an empty range would
        // reject every mid-sentence insertion even though no character is being replaced.
        if range.length == 0 {
            return range.location == text.length || text.rangeOfComposedCharacterSequence(at: range.location).location == range.location
        }
        return text.rangeOfComposedCharacterSequences(for: range) == range
    }
}
