import Foundation
import LingroveTextRules

/// Saved explanation bounds are a data contract, independent of a model's
/// changing token budget. The 262,144-byte context ceiling preserves the old
/// predicate; prompt rendering, parsing and generation remain host-owned.
public nonisolated enum VocabularyExplanationValidation {
    public static let maximumContextBytes = 262_144

    public static func isValid(_ input: LearningExplanationInput) -> Bool {
        !input.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            input.target.utf8.count <= 32_000 && input.dictionaryForm.utf8.count <= 32_000 &&
            input.context.utf8.count <= maximumContextBytes &&
            !input.ranges.isEmpty && input.ranges.count <= 64 &&
            input.ranges.allSatisfy { UTF16TextRangePolicy.isValid($0.nsRange, in: input.context) }
    }

    public static func isValid(_ result: LearningExplanationResult) -> Bool {
        !result.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !result.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            result.meaning.utf8.count <= 2_000 && result.explanation.utf8.count <= 16_000 &&
            UnicodeTextSafety.isSafeToInsert(result.meaning) && UnicodeTextSafety.isSafeToInsert(result.explanation)
    }
}
