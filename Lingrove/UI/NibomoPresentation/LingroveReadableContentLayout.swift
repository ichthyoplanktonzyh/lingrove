// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W3_UI_REUSE_MAP.md.
import SwiftUI

let lingroveReadableContentMaxWidth: CGFloat = 820
let lingroveReadableFormMaxWidth: CGFloat = 720

/// Extracted layout, owned by its parent view. The two width limits keep account forms and card
/// content at Nibomo’s original reading widths without introducing another layout system.
struct LingroveReadableContentLayout<Content: View>: View {
    private let maxWidth: CGFloat
    private let horizontalPadding: CGFloat
    private let alignment: Alignment
    private let content: Content

    init(
        maxWidth: CGFloat,
        horizontalPadding: CGFloat,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.horizontalPadding = horizontalPadding
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        self.content
            .frame(maxWidth: self.maxWidth, alignment: self.alignment)
            .padding(.horizontal, self.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
