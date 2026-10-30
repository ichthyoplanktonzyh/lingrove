import LingroveNotebook
import Foundation

/// The app reuses the shared data rules; platform presentation stays in host extensions.
typealias VocabularyContentPolicy = LingroveNotebook.VocabularyContentPolicy

extension VocabularyContentPolicy {
    nonisolated static func html(_ blocks: [VocabularyContentBlock]) -> String {
        guard !blocks.isEmpty else { return "" }
        let body = blocks.map { block in
            switch block.content {
            case let .text(value):
                var text = ReviewCardPolicy.html(value.text)
                if value.bold { text = "<strong>" + text + "</strong>" }
                if value.italic { text = "<em>" + text + "</em>" }
                switch value.style {
                case .paragraph: return "<p>" + text + "</p>"
                case .heading: return "<h3>" + text + "</h3>"
                case .bullet: return "<ul><li>" + text + "</li></ul>"
                }
            case let .image(image, caption):
                // Inline sizing travels with the field even in existing/custom Anki templates.
                return "<figure style=\"margin:12px 0\"><img src=\"" + image.filename +
                    "\" style=\"max-width:100%;height:auto\" alt=\"" + ReviewCardPolicy.html(caption) + "\">" +
                    (caption.isEmpty ? "" : "<figcaption>" + ReviewCardPolicy.html(caption) + "</figcaption>") + "</figure>"
            }
        }.joined()
        return "<div class=\"sense-explanation\" style=\"font-weight:400;font-size:0.91em\">" + body + "</div>"
    }
}
