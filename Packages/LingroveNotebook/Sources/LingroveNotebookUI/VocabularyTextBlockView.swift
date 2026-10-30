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
        Text((content.style == .bullet ? "• " : "") + content.text)
            .font(font)
            .lineSpacing(3.5)
            .bold(content.bold).italic(content.italic).textSelection(.enabled)
    }
}
