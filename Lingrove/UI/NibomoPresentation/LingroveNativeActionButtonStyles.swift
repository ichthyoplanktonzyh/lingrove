// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_REVIEW_ACCOUNT_UI_REUSE.md.
import SwiftUI

/// The extracted screens keep their existing style entry points while using the same native
/// controls as Lingrove Settings. The system resolves accent, contrast and appearance; the view
/// owning a rating or warning may still supply its semantic tint without changing other actions.
extension View {
    func lingroveNativeActionButtonStyle() -> some View {
        self.buttonStyle(.bordered)
    }

    func lingroveNativeProminentActionButtonStyle() -> some View {
        self.buttonStyle(.borderedProminent)
    }
}
