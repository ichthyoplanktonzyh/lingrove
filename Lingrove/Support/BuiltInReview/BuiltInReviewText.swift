import Foundation

/// Native Text does not lay out the full Markdown parser's paragraph presentation intents.
/// Keeping whitespace while parsing inline syntax preserves the source's separate prompt,
/// translation and meaning paragraphs instead of concatenating them on the rendered face.
/// Views and the existing speech owner consume this pure projection; it performs no media IO.
nonisolated enum BuiltInReviewText {
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func plain(_ text: String) -> String { String(attributed(text).characters) }
}
