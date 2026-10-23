import SwiftUI

/// Centralized motion tokens for the Settings window.
///
/// Why a dedicated token namespace:
/// Scattering ad-hoc `easeOut` and `easeInOut` curves across panes makes progressive disclosure,
/// hover states, and live previews feel disconnected. Defining critically damped springs (`dampingFraction`
/// near `0.88–0.92`) in one place gives every Settings transition the same responsive, interruptible
/// physical character while honoring `accessibilityReduceMotion` at the boundary.
enum SettingsMotion {
    /// Critically damped spring for progressive disclosure (revealing dependent rows or sections).
    static let disclosure = Animation.spring(response: 0.30, dampingFraction: 0.88)

    /// Snappy spring for direct control feedback (selection rings, swatches, live preview updates).
    static let interaction = Animation.spring(response: 0.22, dampingFraction: 0.90)

    /// Smooth spring for programmatic scroll-to-row reveals from search.
    static let scroll = Animation.spring(response: 0.36, dampingFraction: 0.90)

    /// Returns `nil` when the user has requested reduced motion, allowing callers to wrap state
    /// mutations in `withAnimation(SettingsMotion.resolved(..., reduceMotion: reduceMotion))` without
    /// branching at every call site.
    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// File overview:
/// Shared chrome for every settings detail pane. Pulls the form styling, scrolling, and
/// optional top-of-pane callout into one place so individual panes stay focused on their rows
/// rather than repeating layout boilerplate.
///
/// Why a callout slot:
/// The legacy settings window puts a single attention banner at the top of the form. The redesign
/// surfaces attention per pane: when a pane is in a degraded state (missing permission, runtime
/// unavailable) we render an inline callout above the form so the actionable surface lives next to
/// the controls that fix it.
///
/// Search arrival:
/// When search reveals a specific setting, the scaffold scrolls to the row carrying the matching
/// `.settingsItem(_:)` anchor. The row's own modifier renders the pulse; the scaffold only owns
/// the scroll, so panes stay declarative.
struct SettingsPaneScaffold<Content: View>: View {
    let callout: SettingsPaneCallout?
    @ViewBuilder let content: () -> Content

    @Environment(\.settingsHighlightedItem) private var highlightedItem
    @Environment(\.settingsRevealSequence) private var revealSequence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A short-lived task identity combines the row and the explicit navigation action.
    /// The scaffold owns it so ordinary layout updates cannot trigger repeated scrolling.
    private struct Arrival: Hashable {
        let item: SettingsItem?
        let sequence: Int
    }

    init(
        callout: SettingsPaneCallout? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.callout = callout
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            // Grouped Form already supplies its native scroll container. An outer ScrollView
            // gives the reader a second scroll owner, so revealing a Form row can leave the
            // visible viewport at the top. One owner lets the proxy reach the row's actual scroller.
            Form {
                if let callout {
                    Section {
                        SettingsCalloutView(callout: callout)
                    }
                }
                content()
            }
            .formStyle(.grouped)
            // Header-less first sections need the same clearance below the title bar. The shared
            // callout is a section of this document, so it continues scrolling with the controls.
            .padding(.top, 12)
            .task(id: Arrival(item: highlightedItem, sequence: revealSequence)) {
                // The first reveal can precede row layout after `.id(selection)` rebuilds the
                // pane. SwiftUI cancels this task when a new target arrives or the pane disappears.
                // Reveal once, rather than issuing a delayed repair that can pull the viewport
                // back after the user starts scrolling. Same-pane searches use the same path.
                guard let item = highlightedItem else { return }
                do {
                    try await Task.sleep(for: .milliseconds(80))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation(SettingsMotion.resolved(SettingsMotion.scroll, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(item, anchor: .center)
                }
            }
        }
    }
}

struct SettingsPaneCallout: Equatable {
    enum Tone {
        case warning
        case info
    }

    let tone: Tone
    let message: String
}

/// Renders a single callout (warning/info) with a tinted background and matching icon. Used both by
/// the scaffold's top-of-pane slot and inline inside a pane section when an attention message belongs
/// next to a specific control (e.g. the Extended Context cost warning in the Advanced pane).
struct SettingsCalloutView: View {
    let callout: SettingsPaneCallout

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .imageScale(.medium)

            Text(callout.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.4), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch callout.tone {
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch callout.tone {
        case .warning: return .orange
        case .info: return .accentColor
        }
    }
}
