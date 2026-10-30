import LingroveTextRules
import Foundation

/// File overview:
/// Rejects completions that are technically non-empty but would insert nothing a user wants.
///
/// Why this file exists:
/// `SuggestionInserter` previously only refused a fully empty string, so a completion carrying an
/// interior control character or a U+FFFD replacement glyph (from lossy detokenization) could reach
/// ghost text and be committed on Tab. This gate is the single predicate for "is this safe to put
/// on screen and insert."
///
/// Scope note: this intentionally does NOT reject punctuation-only output. A lone ")", ".", or "?"
/// is a legitimate inline completion (closing a bracket, ending a sentence), so judging punctuation
/// here would suppress useful suggestions. The gate is limited to unambiguous junk.
nonisolated enum InsertionSafetyGate {
    /// Returns true when `completion` is safe to display and insert.
    static func isSafeToInsert(_ completion: String) -> Bool {
        UnicodeTextSafety.isSafeToInsert(completion)
    }
}
