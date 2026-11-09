import LingroveNotebook
import SwiftUI

/// A reading surface borrows one saved text block. The host chooses the font
/// for its reading scale or Dynamic Type policy; this view owns only the common
/// formatting. Keeping images and actions outside this boundary avoids bringing
/// AppKit, a concrete store or a generation session into the shared UI product.
@MainActor
public struct VocabularyTextBlockView: View {
    private let content: VocabularyTextContent
    private let font: Font

    public init(content: VocabularyTextContent, font: Font) {
        self.content = content
        self.font = font
    }

    public var body: some View {
        Text(attributedText)
            .font(font)
            .lineSpacing(3.5)
            .textSelection(.enabled)
    }
    private var attributedText: AttributedString {
        var result = AttributedString(content.style == .bullet ? "• " : "")
        for segment in content.segments {
            var part = AttributedString(segment.text)
            var intent: InlinePresentationIntent = []
            if segment.bold { intent.insert(.stronglyEmphasized) }
            if segment.italic { intent.insert(.emphasized) }
            part.inlinePresentationIntent = intent
            result.append(part)
        }
        return result
    }

}
