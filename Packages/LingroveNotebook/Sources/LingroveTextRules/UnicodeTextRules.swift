import Foundation

/// Deterministic Unicode checks shared by autocomplete and saved explanations.
/// There is no model, notebook or UI ownership here: callers supply an immutable
/// string, and the same predicate rejects control/replacement characters.
public nonisolated enum UnicodeTextSafety {
    public static func isSafeToInsert(_ completion: String) -> Bool {
        guard !completion.isEmpty else {
            return false
        }

        var sawNonWhitespace = false
        for scalar in completion.unicodeScalars {
            // Replacement character: the detokenizer produced bytes it could not decode. Never text.
            if scalar == "\u{FFFD}" {
                return false
            }
            // C0 control range and DEL. A line feed is legitimate content in a multi-line completion
            // (the normalizer keeps newlines when multi-line mode is on), so it must pass; any other
            // control character (an interior tab, a stray escape) is corruption, not content.
            if scalar.value != 0x0A, scalar.value < 0x20 || scalar.value == 0x7F {
                return false
            }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                sawNonWhitespace = true
            }
        }

        // Whitespace-only output is not a completion.
        return sawNonWhitespace
    }
}

/// Stored evidence and Mac text geometry use UTF-16 coordinates. Check bounds
/// before asking Foundation for composed-character ranges, including Int.max
/// and surrogate/combining-sequence boundaries. This rule performs no IO.
public nonisolated enum UTF16TextRangePolicy {
    public static func isValid(_ range: NSRange, in text: String) -> Bool {
        range.location >= 0 && range.length > 0 && range.location <= text.utf16.count &&
            range.length <= text.utf16.count - range.location && Range(range, in: text) != nil &&
            (text as NSString).rangeOfComposedCharacterSequences(for: range) == range
    }
}
