import AppKit
import SwiftUI

/// File overview:
/// Small, focused components used by the menu-bar panel.
/// These stay purely presentational; app-owned settings and controllers retain behavior.

/// Menu actions describe their destination; the app's one SettingsCoordinator performs the
/// navigation after the popover has closed, retaining the same window and settings instances.
enum MenuBarSettingsDestination {
    case category(SettingsCategory)
    case learning(SettingsLearningTask)
    case model(SettingsEngineTask)
}

/// Learning content can grow with disclosures or missing permissions; completion does not use
/// this container, retaining its original natural layout.
/// Measure the scrolling document independently of its viewport: short pages keep their native
/// height, while tall pages scroll without pushing the permanent footer off a small display.
struct MenuBarContentViewport<Content: View>: View {
    let maximumHeight: CGFloat
    let content: Content
    @State private var contentHeight: CGFloat = 0

    init(maximumHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maximumHeight = maximumHeight
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MenuBarContentHeight.self, value: geometry.size.height)
                })
        }
        .frame(height: min(maximumHeight, contentHeight > 0 ? contentHeight : maximumHeight))
        .onPreferenceChange(MenuBarContentHeight.self) { height in
            if abs(height - contentHeight) > 0.5 { contentHeight = height }
        }
    }
}

private struct MenuBarContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Compact labeled row for menu-bar pickers. Keeps label width consistent across
/// Engine / Model / Length rows without a heavy generic layout container.
struct MenuBarPickerRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A single permission row with a checkmark/x indicator and an inline "Grant" button.
///
/// The row measures the Grant button in screen coordinates so callers can anchor AppKit overlays
/// to the exact clicked control. That keeps the menu row presentational while still giving the
/// permission-guidance service the geometry it needs for its cross-window animation.
struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: (CGRect?) -> Void

    @State private var actionButtonFrame = CGRect.zero

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption)
                .foregroundStyle(granted ? .green : .orange)

            Text(title)
                .font(.caption)

            Spacer(minLength: 0)

            if !granted {
                Button("Grant") {
                    action(actionButtonFrame.isEmpty ? nil : actionButtonFrame)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .background(ScreenFrameReader(frameInScreen: $actionButtonFrame))
            }
        }
    }
}
