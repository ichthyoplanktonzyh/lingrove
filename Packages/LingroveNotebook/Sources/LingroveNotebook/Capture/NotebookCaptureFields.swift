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

    /// The reader picks one definition per language. Use that same view of saved variants when
    /// checking conflicts so an additive write cannot silently hide or replace learner wording.
    static func addMeaningVariants(_ variants: [VocabularyMeaning], to sense: inout VocabularySense) throws {
        var visible = VocabularyContentPolicy.languageVariants(
            text: sense.meaning, language: sense.meaningLanguage, variants: sense.standaloneMeanings)
        for variant in variants {
            _ = try text(variant.text, limit: 32_000, nonempty: true)
            if let existing = visible.first(where: { $0.language == variant.language }) {
                guard existing == variant else {
                    throw NotebookToolError(code: .conflict, message: "A core meaning already exists in this language.")
                }
                continue
            }
            sense.standaloneMeanings.append(variant)
            visible.append(variant)
        }
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
              let completeness = VocabularyExample.Completeness(rawValue: input.completeness ?? "sentence"),
              let sourceKind = VocabularyExample.SourceKind(rawValue: input.sourceKind ?? "authored") else {
            throw NotebookToolError.invalid("Invalid UTF-16 ranges, context completeness or source kind.")
        }
        return .init(id: id, sourceID: input.sourceID ?? id, sourceKind: sourceKind,
            text: text, translation: try self.text(input.translation ?? "", limit: 262_144),
            translationLanguage: try language(input.translationLanguage), ranges: ranges, completeness: completeness,
            meaning: "", createdAt: now)
    }
}
