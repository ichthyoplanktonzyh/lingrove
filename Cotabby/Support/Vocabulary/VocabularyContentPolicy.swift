import Foundation

/// Pure content rules are shared by archive validation, editing and review. No file access or
/// model work occurs here; both notebook and Anki use the same meaningful-content definition.
nonisolated enum VocabularyContentPolicy {
    static let maximumImageBytes = 4 * 1_024 * 1_024
    static let maximumSenseImageBytes = 16 * 1_024 * 1_024
    static let maximumDimension = 1_600

    static func images(_ blocks: [VocabularyContentBlock]) -> [VocabularyImageReference] {
        blocks.compactMap { if case let .image(image, _) = $0.content { image } else { nil } }
    }

    static func meaningful(_ blocks: [VocabularyContentBlock]) -> Bool {
        blocks.contains {
            switch $0.content {
            case let .text(value): !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image: true
            }
        }
    }

    static func valid(_ image: VocabularyImageReference) -> Bool {
        image.digest.count == 64 && image.digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            (1...maximumDimension).contains(image.width) && (1...maximumDimension).contains(image.height) &&
            (1...maximumImageBytes).contains(image.byteCount)
    }

    static func validate(_ blocks: [VocabularyContentBlock]) throws {
        guard blocks.count <= 64, Set(blocks.map(\.id)).count == blocks.count else {
            throw VocabularyError.invalidContent
        }
        for block in blocks {
            switch block.content {
            case let .text(value):
                guard value.text.utf8.count <= 262_144 else { throw VocabularyError.invalidContent }
            case let .image(image, caption):
                guard valid(image), caption.utf8.count <= 16_384 else { throw VocabularyError.invalidContent }
            }
        }
        // Validate each count before summing: imported JSON may contain Int.max, which must
        // produce a recoverable validation error rather than an integer-overflow trap.
        guard images(blocks).reduce(0, { $0 + $1.byteCount }) <= maximumSenseImageBytes else {
            throw VocabularyError.invalidContent
        }
    }

    static func html(_ blocks: [VocabularyContentBlock]) -> String {
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
