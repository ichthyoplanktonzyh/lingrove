import Foundation

/// Pure trigger and text-range rules. AX uses UTF-16 offsets; validating composed-character
/// boundaries here prevents a custom Unicode trigger from splitting an emoji or combining mark.
nonisolated enum ExpressionAssistPolicy {
    static func triggerError(_ trigger: String) -> String? {
        guard (2...8).contains(trigger.count), trigger.allSatisfy({ $0.isPunctuation || $0.isSymbol }) else {
            return String(localized: "Use 2–8 punctuation marks or symbols without spaces.", table: "Learning")
        }
        guard !trigger.hasPrefix(":"), !trigger.hasPrefix("/") else {
            return String(localized: "Choose a trigger that does not start with : or /; those open emoji and macros.", table: "Learning")
        }
        return nil
    }

    static func matchedTrigger(beforeCaret: String, configured: String) -> String? {
        guard triggerError(configured) == nil else { return nil }
        let variants = configured == "??" ? [configured, "？？"] : [configured]
        // The configured punctuation is the explicit command boundary. Requiring a separator
        // before it prevents natural slots such as Chinese text + ？？ or an English word + ??.
        return variants.first { beforeCaret.hasSuffix($0) }
    }

    static func text(_ value: String, range: NSRange) throws -> String {
        try EditorTextRangePolicy.text(value, range: range)
    }

    static func request(query: String, value: String, range: NSRange,
                        target: LearningLanguage, explanation: LearningLanguage) throws -> ExpressionAssistRequest {
        let selected = try text(value, range: range)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 2_000, selected.utf8.count <= 2_000 else {
            throw LearningFailure.message(String(localized: "Keep the expression description and selection under 2 KB each.",
                table: "Learning"))
        }
        let source = value as NSString
        let before = source.substring(to: range.location)
        let after = source.substring(from: NSMaxRange(range))
        // Preserve whole Characters while bounding both sides independently. The nearest paragraph
        // is sufficient for slot grammar; unrelated document history never enters this request.
        let left = before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let right = after.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return .init(query: query, leftContext: String(left.suffix(700)), rightContext: String(right.prefix(500)),
            selectedText: selected, targetLanguage: target.rawValue, explanationLanguage: explanation.rawValue)
    }
}
