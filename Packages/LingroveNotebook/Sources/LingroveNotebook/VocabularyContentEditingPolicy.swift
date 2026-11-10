import Foundation
import LingroveTextRules

/// Agents read plain text and edit exact fragments; they never need to reconstruct native
/// formatting. These values address storage parts, not separate user-facing editor sections.
public nonisolated struct VocabularyContentEdit: Codable, Sendable {
    public var blockID: UUID
    public var find: String?
    public var replacement: String?
    public var caption: String?
    public var remove: Bool?
}

/// A deterministic edit preserves untouched text marks, paragraph style and image references.
/// The enclosing sense command owns revision checks and persistence; no platform rich-text
/// objects or model calls cross this module's interface.
public nonisolated enum VocabularyContentEditingPolicy {
    public static func replacePlainExplanation(_ text: String, in sense: inout VocabularySense, id: UUID) throws {
        let text = try NotebookCaptureFields.text(text, limit: 262_144)
        guard (sense.content ?? []).allSatisfy({ block in
            guard case let .text(value) = block.content else { return false }
            return value.style == .paragraph && !value.bold && !value.italic && (value.runs ?? []).isEmpty
        }) else {
            throw NotebookToolError.invalid("This explanation contains images or formatting. Use contentEdits to preserve them.")
        }
        let retainedID = sense.content?.count == 1 ? (sense.content?.first?.id ?? id) : id
        sense.content = text.isEmpty ? [] : [.init(id: retainedID, content: .text(.init(text: text)))]
    }

    public static func apply(_ edits: [VocabularyContentEdit], to sense: inout VocabularySense) throws {
        var blocks = sense.content ?? []
        for edit in edits {
            guard let index = blocks.firstIndex(where: { $0.id == edit.blockID }) else {
                throw NotebookToolError(code: .notFound, message: "Explanation part no longer belongs to this sense.")
            }
            let isText = edit.find != nil || edit.replacement != nil
            guard [isText, edit.caption != nil, edit.remove == true].filter({ $0 }).count == 1,
                  edit.remove == nil || edit.remove == true else {
                throw NotebookToolError.invalid("Each content edit needs find/replacement, caption, or remove: true.")
            }
            if edit.remove == true { blocks.remove(at: index); continue }
            if let caption = edit.caption {
                guard case let .image(reference, _) = blocks[index].content else {
                    throw NotebookToolError.invalid("Captions belong to image parts only.")
                }
                blocks[index].content = .image(reference, caption: try NotebookCaptureFields.text(caption, limit: 16_384))
            } else {
                guard case var .text(value) = blocks[index].content, let find = edit.find, let replacement = edit.replacement else {
                    throw NotebookToolError.invalid("Text edits require a text part, find, and replacement.")
                }
                try replace(find: find, with: replacement, in: &value)
                blocks[index].content = .text(value)
            }
        }
        try VocabularyContentPolicy.validate(blocks)
        sense.content = blocks
    }

    private static func replace(find: String, with replacement: String, in value: inout VocabularyTextContent) throws {
        let find = try NotebookCaptureFields.text(find, limit: 262_144, nonempty: true)
        let replacement = try NotebookCaptureFields.text(replacement, limit: 262_144)
        let text = value.text as NSString
        let range = text.range(of: find, options: .literal)
        guard range.location != NSNotFound, UTF16TextRangePolicy.isValid(range, in: value.text) else {
            throw NotebookToolError(code: .conflict, message: "Text fragment was not found at a valid character boundary. Read the sense again.")
        }
        let tail = NSRange(location: range.location + 1, length: text.length - range.location - 1)
        guard text.range(of: find, options: .literal, range: tail).location == NSNotFound else {
            throw NotebookToolError(code: .conflict, message: "Text fragment is ambiguous. Include more surrounding text.")
        }
        let start = range.location, end = NSMaxRange(range), delta = replacement.utf16.count - range.length
        var marks: [VocabularyTextRun] = []
        func retain(_ location: Int, _ length: Int, _ run: VocabularyTextRun) {
            if length > 0 { marks.append(.init(location: location, length: length, bold: run.bold, italic: run.italic)) }
        }
        for run in value.runs ?? [] {
            let lower = run.location, upper = lower + run.length
            if upper <= start { marks.append(run) }
            else if lower >= end { retain(lower + delta, run.length, run) }
            else if lower <= start && upper >= end { retain(lower, run.length + delta, run) }
            else {
                retain(lower, max(0, start - lower), run)
                if upper > end { retain(end + delta, upper - end, run) }
            }
        }
        value.text = text.replacingCharacters(in: range, with: replacement)
        value.runs = marks.isEmpty ? nil : marks
    }
}
