import Foundation

/// Validates complete text returned by the learning endpoint before a translation preview or a
/// structured hint decoder can consume it. This boundary keeps output size and insertion safety
/// consistent even though translation and hints have different response formats.
nonisolated enum LearningExpressionOutputPolicy {
    /// Request-local accumulation at the translation service boundary. Native/HTTP deltas are
    /// already valid UTF-8; this value bounds the entire stream and applies the same text-safety
    /// policy before any prefix reaches a view. Prefixes never certify generation completion.
    struct Stream {
        private var raw = ""
        mutating func append(_ delta: String) throws -> String? {
            guard delta.utf8.count <= 12_000 - raw.utf8.count else {
                throw LearningExpressionOutputPolicy.invalidOutput()
            }
            raw += delta
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return try LearningExpressionOutputPolicy.validatedText(raw)
        }
    }

    static func validatedText(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 12_000, InsertionSafetyGate.isSafeToInsert(text) else {
            throw invalidOutput()
        }
        return text
    }

    private static func invalidOutput() -> LearningFailure {
        .message(String(localized: """
            The model returned empty, oversized, or unsafe-to-insert text. The original text was kept.
            """,
                table: "Learning", comment: "Error shown when generated text fails validation and is not inserted into the editor."))
    }
}
