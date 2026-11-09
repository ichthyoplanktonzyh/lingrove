import Foundation
import LingroveTextRules

/// Field normalization and occurrence construction used by capture and CLI batch operations.
public nonisolated enum NotebookCaptureFields {
    public static func text(_ value: String, limit: Int, nonempty: Bool = false) throws -> String {
        guard value.utf8.count <= limit, !nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotebookToolError.invalid("Text is empty or exceeds its field limit.")
        }
        return value
    }
    public static func language(_ value: String?) throws -> LearningLanguage? {
        guard let value else { return nil }
        guard let language = LearningLanguage(rawValue: value) else { throw NotebookToolError.invalid("Unknown language code.") }
        return language
    }
    public static func tags(_ values: [String]) throws -> [String] {
        guard values.count <= 100 else { throw NotebookToolError.invalid("At most 100 tags are allowed.") }
        var result: [String] = []
        for value in values {
            let tag = try text(value.trimmingCharacters(in: .whitespacesAndNewlines), limit: 200, nonempty: true)
            if !result.contains(tag) { result.append(tag) }
        }
        return result
    }
    public static func example(_ input: NotebookCaptureExample, expression: String, id: UUID, now: Date) throws -> VocabularyExample {
        let text = try text(input.text, limit: 262_144, nonempty: true)
        let ranges: [VocabularyTextRange]
        if let supplied = input.ranges {
            ranges = supplied.map { .init(NSRange(location: $0.location, length: $0.length)) }
        } else {
            let range = (text as NSString).range(of: expression)
            if range.location != NSNotFound {
                // Start after the first start, not its end: targets such as "ana" in
                // "banana" have overlapping occurrences and still require disambiguation.
                let tail = NSRange(location: range.location + 1, length: text.utf16.count - range.location - 1)
                guard (text as NSString).range(of: expression, range: tail).location == NSNotFound else {
                    throw NotebookToolError.invalid("Expression occurs more than once. Supply explicit UTF-16 ranges.")
                }
            }
            ranges = range.location == NSNotFound ? [] : [.init(range)]
        }
        guard ranges.count <= 64, ranges.allSatisfy({ UTF16TextRangePolicy.isValid($0.nsRange, in: text) }),
              let completeness = VocabularyExample.Completeness(rawValue: input.completeness ?? "sentence") else {
            throw NotebookToolError.invalid("Invalid UTF-16 ranges or context completeness.")
        }
        return .init(id: id, sourceID: id, sourceKind: VocabularyExample.SourceKind(rawValue: input.sourceKind ?? "authored") ?? .authored,
            text: text, translation: try self.text(input.translation ?? "", limit: 262_144),
            translationLanguage: try language(input.translationLanguage), ranges: ranges, completeness: completeness,
            meaning: "", createdAt: now)
    }
}
