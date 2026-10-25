import AppKit
import SwiftUI

/// File overview:
/// Reusable presentational building blocks for the menu-bar popover (`MenuBarView` and
/// `MenuBarLearningControls`).
///
/// Architectural boundary:
/// These views own visual grouping (Control-Center-style surface cards), consistent left-label /
/// right-control alignment, and pointer hover/press micro-interactions. They remain strictly
/// stateless with respect to app services; durable preferences and navigation callbacks are passed
/// in by `MenuBarView` and `MenuBarLearningControls`.

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

// MARK: - Surface & Grouping Primitives

/// A lightweight translucent card used to group related controls inside the menu-bar popover,
/// inspired by macOS Control Center modules. Replaces raw edge-to-edge dividers with calm
/// spatial grouping.
struct MenuBarSurfaceCard<Content: View>: View {
    var padding: CGFloat = 10
    var spacing: CGFloat = 8
    var tint: Color?
    let content: Content

    init(
        padding: CGFloat = 10,
        spacing: CGFloat = 8,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.spacing = spacing
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.map { $0.opacity(0.08) } ?? Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    tint.map { $0.opacity(0.22) } ?? Color.primary.opacity(0.06),
                    lineWidth: 0.5
                )
        )
    }
}

/// Full-bleed hairline divider with subtle opacity for separating logical rows inside a
/// `MenuBarSurfaceCard`.
struct MenuBarCardDivider: View {
    var body: some View {
        Divider()
            .opacity(0.55)
    }
}

// MARK: - Aligned Control Rows

/// Standard menu-bar switch row that pins the label on the leading edge and the `.switch` control
/// on the trailing edge. Using `Toggle` with a custom `HStack` label or explicit spacer prevents
/// switches from sitting at ragged horizontal offsets after variable-length titles.
struct MenuBarToggleRow: View {
    let title: String
    var systemImage: String?
    var subtitle: String?
    @Binding var isOn: Bool
    var isDisabled: Bool = false
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .center)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let identifier {
                    Toggle(title, isOn: $isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(isDisabled)
                        .accessibilityLabel(title)
                        .accessibilityIdentifier(identifier)
                } else {
                    Toggle(title, isOn: $isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(isDisabled)
                        .accessibilityLabel(title)
                }
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, systemImage != nil ? 24 : 0)
            }
        }
    }
}

/// Compact labeled row for menu-bar pickers and trailing controls.
///
/// Why this layout avoids a hardcoded label width:
/// Short labels ("Engine", "Model", "Length") and longer localized labels ("Target language",
/// "Explanation language") coexist across tabs. Keeping the label on a single line and giving the
/// trailing control a flexible right-aligned slot prevents awkward multi-line wrapping while
/// maintaining a clean two-column rhythm.
struct MenuBarPickerRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 6)

            content
                .frame(maxWidth: 196, alignment: .trailing)
        }
    }
}

// MARK: - Interactive Menu Buttons

/// Button style that provides macOS menu-like hover illumination and subtle press-down scale
/// feedback (`0.985`). Respects `accessibilityReduceMotion` by skipping the scale transform when
/// reduced motion is enabled.
struct MenuBarInteractiveRowButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 5
    var cornerRadius: CGFloat = 7
    var tint: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: tint != nil ? 0.5 : 0)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
            }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if let tint {
            if isPressed { return tint.opacity(0.24) }
            if isHovering { return tint.opacity(0.18) }
            return tint.opacity(0.12)
        }
        if isPressed {
            return Color.primary.opacity(0.11)
        }
        if isHovering {
            return Color.primary.opacity(0.065)
        }
        return .clear
    }

    private var borderColor: Color {
        guard let tint else { return .clear }
        return tint.opacity(isHovering ? 0.42 : 0.28)
    }
}

/// Hover-aware pill wrapper for controls like `Menu` whose native AppKit `.borderlessButton`
/// style does not draw its own hover background.
struct MenuBarHoverPill<Content: View>: View {
    var horizontalPadding: CGFloat = 7
    var verticalPadding: CGFloat = 3
    var cornerRadius: CGFloat = 6
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    init(
        horizontalPadding: CGFloat = 7,
        verticalPadding: CGFloat = 3,
        cornerRadius: CGFloat = 6,
        @ViewBuilder content: () -> Content
    ) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.065) : Color.clear)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

/// Full-width navigable action row with a leading icon, primary label, and optional trailing
/// shortcut hint or chevron. Used for destinations like Vocabulary, Dictionary, Review, and
/// Language Learning settings.
struct MenuBarActionRow: View {
    let title: String
    let systemImage: String
    var iconTint: Color = .secondary
    var trailingText: String?
    var showsChevron: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: 16, alignment: .center)

                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let trailingText {
                    Text(trailingText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuBarInteractiveRowButtonStyle())
    }
}

/// Compact icon button with hover pill feedback, used for inline utility actions such as opening
/// the local models folder or refreshing the model list.
struct MenuBarIconButton: View {
    let systemImage: String
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(MenuBarInteractiveRowButtonStyle(horizontalPadding: 2, verticalPadding: 2, cornerRadius: 5))
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

// MARK: - Permissions

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
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(granted ? .green : .orange)

            Text(title)
                .font(.caption)
                .foregroundStyle(granted ? .secondary : .primary)

            Spacer(minLength: 0)

            if !granted {
                Button("Grant") {
                    action(actionButtonFrame.isEmpty ? nil : actionButtonFrame)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
                .buttonStyle(
                    MenuBarInteractiveRowButtonStyle(
                        horizontalPadding: 8,
                        verticalPadding: 2,
                        cornerRadius: 99,
                        tint: .accentColor
                    )
                )
                .background(ScreenFrameReader(frameInScreen: $actionButtonFrame))
            }
        }
    }
}
