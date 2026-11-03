// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W3_UI_REUSE_MAP.md.
import SwiftUI

/// Mechanical macOS availability port of Nibomo’s standard action styles. Parents supply tint;
/// the OS supplies glass on 26 and the existing bordered fallback on earlier systems.
extension View {
    @ViewBuilder
    func lingroveNativeActionButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func lingroveNativeProminentActionButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
