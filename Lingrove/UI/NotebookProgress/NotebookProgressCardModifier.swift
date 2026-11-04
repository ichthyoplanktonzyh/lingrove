// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_PROGRESS_UI_REUSE.md.
import SwiftUI
import LingroveNotebookEngine

/// Every Progress section borrows this small native card treatment from its destination.
/// Semantic control backgrounds and separators resolve at render time for the owning window;
/// this modifier carries no theme state and does not affect other hosting subtrees.
struct NotebookProgressCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
            }
    }
}
