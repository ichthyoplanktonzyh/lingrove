// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_REVIEW_ACCOUNT_UI_REUSE.md.
import SwiftUI

let lingroveReadableContentMaxWidth: CGFloat = 820
let lingroveReadableFormMaxWidth: CGFloat = 720

/// A presentation-only width boundary retained by the extracted review views. It centers reading
/// material inside the native destination without owning scroll position, colors or services.
/// Account forms use SettingsPaneScaffold directly so they share the existing Settings viewport.
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
