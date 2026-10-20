import Foundation

/// Pure validation shared by imports, provider requests and cross-reference navigation. No
/// dictionary text can turn into an unbounded query, filesystem path, or executable URL.
nonisolated enum DictionaryContentPolicy {
    static func validQuery(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 256 && InsertionSafetyGate.isSafeToInsert(text)
    }

    static func resourcePath(_ path: String) -> String? {
        let value = path.removingPercentEncoding ?? path
        let normalized = value.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty, normalized.utf8.count <= 2048, !normalized.contains("\0"),
              !normalized.contains(":"), !normalized.split(separator: "/").contains("..") else { return nil }
        return normalized
    }

    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func plainText(_ html: String) -> String {
        let cleaned = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>",
                                                with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</?(?:div|p|br|li|h[1-6]|tr)\\b[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return cleaned.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
