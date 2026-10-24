import SwiftUI

/// File overview:
/// Renders the tiny menu-bar label hosted inside the native status button. It stays separate
/// from the popover pages so icon/status updates do not rebuild the larger menu.
///
/// The controller borrows this view rather than constructing another settings/coordinator graph.
/// Observing the existing coordinator directly updates both the displayed accepted-word count
/// and the native button's accessibility text.
struct MenuBarStatusLabelView: View {
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    var body: some View {
        HStack(spacing: 2) {
            Image("MenuBarWhaleIcon")
                .renderingMode(.template)
                // Match the asset's 18-point canvas so macOS uses its native 1x/2x strokes.
                .frame(width: 18, height: 18)
                .accessibilityLabel(String(localized: "Lingrove", table: "Learning"))

            if suggestionSettings.isTemporarilyPaused || !suggestionSettings.isGloballyEnabled {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityLabel(inactiveAccessibilityLabel)
            }

            if suggestionSettings.isMenuBarWordCountVisible,
               let label = WordCountFormatter.compactLabel(
                   for: suggestionCoordinator.totalTabAcceptedWordCount
               ) {
                Text(label)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
        }
        .preference(key: MenuBarStatusAccessibilityKey.self, value: statusAccessibilityLabel)
    }

    private var statusAccessibilityLabel: String {
        var parts = [String(localized: "Lingrove", table: "Learning")]
        if suggestionSettings.isTemporarilyPaused || !suggestionSettings.isGloballyEnabled {
            parts.append(inactiveAccessibilityLabel)
        }
        if suggestionSettings.isMenuBarWordCountVisible,
           let count = WordCountFormatter.compactLabel(for: suggestionCoordinator.totalTabAcceptedWordCount) {
            parts.append(count)
        }
        return parts.joined(separator: ", ")
    }

    /// VoiceOver needs the persistent global disable state distinguished from a temporary pause.
    /// Global disable takes precedence when both states are present because it remains in effect
    /// after the temporary pause is cleared.
    private var inactiveAccessibilityLabel: String {
        suggestionSettings.isGloballyEnabled ? String(
            localized: "Lingrove paused",
            table: "Learning"
        ) : String(
            localized: "Lingrove disabled",
            table: "Learning"
        )
    }
}

/// Passes the existing label's dynamic semantics to the native status button. The label still
/// owns formatting and observes the app settings; the container only applies the resulting text.
struct MenuBarStatusAccessibilityKey: PreferenceKey {
    static let defaultValue = ""
    static func reduce(value: inout String, nextValue: () -> String) { value = nextValue() }
}
