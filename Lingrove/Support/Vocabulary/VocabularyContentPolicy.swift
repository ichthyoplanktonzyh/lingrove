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
                var text = ReviewTemplateRenderer.escapeHTML(value.text).replacingOccurrences(of: "\n", with: "<br>")
                if value.bold { text = "<strong>" + text + "</strong>" }
                if value.italic { text = "<em>" + text + "</em>" }
                switch value.style {
                case .paragraph: return "<p>" + text + "</p>"
                case .heading: return "<h3>" + text + "</h3>"
                case .bullet: return "<ul><li>" + text + "</li></ul>"
                }
            case let .image(image, caption):
                let escapedCaption = ReviewTemplateRenderer.escapeHTML(caption).replacingOccurrences(of: "\n", with: "<br>")
                // Inline sizing travels with the field even in existing/custom Anki templates.
                return "<figure style=\"margin:12px 0\"><img src=\"" + image.filename +
                    "\" style=\"max-width:100%;height:auto\" alt=\"" + escapedCaption + "\">" +
                    (caption.isEmpty ? "" : "<figcaption>" + escapedCaption + "</figcaption>") + "</figure>"
            }
        }.joined()
        return "<div class=\"sense-explanation\" style=\"font-weight:400;font-size:0.91em\">" + body + "</div>"
    }
}
