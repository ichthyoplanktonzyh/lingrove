import SwiftUI

/// File overview:
/// Lingrove's brand palette and reusable identity primitives, shared by every surface that speaks
/// in the brand voice (onboarding, the permission reminder, the Settings window, the Vocabulary
/// notebook workspace, account sheets, and inline learning cards).
///
/// Why this file exists as its own boundary:
/// Centralizing the brand colors, squircle logo geometry (`size * 0.225`), ambient glow, sidebar
/// wordmark header, and whale glyph in one place prevents individual panes or popovers from
/// hardcoding inconsistent corner radii, shadows, or fallback SF Symbols.
enum LingroveBrand {
    /// The existing blue UI accent stays available for controls and blue-tinted brand moments;
    /// it remains independent of the whale logo's navy and turquoise colors. Identical in both
    /// appearances.
    static let accent = Color(red: 0.0, green: 0.478, blue: 1.0)

    /// Lighter companion to `accent`, used as the top stop of icon-tile and pip gradients so
    /// tinted elements read as lit from above (the System Settings icon treatment).
    static let accentSoft = Color(red: 0.33, green: 0.63, blue: 1.0)

    /// Asset catalog name for the full-color squircle application icon.
    static let logoAssetName = "LingroveLogo"

    /// Asset catalog name for the monochrome whale template silhouette.
    static let whaleTemplateIconAssetName = "MenuBarWhaleIcon"
}

/// Renders the full-color `LingroveLogo` app icon inside a continuous macOS squircle with a
/// subtle inner rim highlight and an optional brand-blue ambient shadow.
///
/// Collaborators:
/// Used by `LingroveSidebarBrandHeader`, `LingroveBrandEmblem`, `ProductUsageGuideView`,
/// `LingroveAccountSignInSheet`, `AccountPaneView`, `LearningTranslationCard`, and
/// `PermissionReminderView`. Stateless value view owned by its parent view tree.
struct LingroveLogoBadge: View {
    var size: CGFloat = 28
    var showsGlow: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var cornerRadius: CGFloat {
        round(size * 0.225 * 2) / 2
    }

    var body: some View {
        Image(LingroveBrand.logoAssetName)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.14 : 0.22),
                        lineWidth: 0.5
                    )
            )
            .shadow(
                color: showsGlow
                    ? LingroveBrand.accent.opacity(colorScheme == .dark ? 0.36 : 0.26)
                    : Color.black.opacity(0.08),
                radius: showsGlow ? max(4, size * 0.22) : 2,
                y: showsGlow ? max(1.5, size * 0.08) : 1
            )
            .accessibilityHidden(true)
    }
}

/// Compact monochrome whale silhouette (`MenuBarWhaleIcon`) for inline learning cards, section
/// headers, and badges where a full-color app icon tile would be too heavy.
struct LingroveWhaleGlyph: View {
    var size: CGFloat = 13
    var tint: Color = LingroveBrand.accent

    var body: some View {
        Image(LingroveBrand.whaleTemplateIconAssetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}

/// Shared top-of-sidebar identity bar used by both `NotebookWorkspaceSidebar` and
/// `SettingsSidebarView` so the app's two primary multi-column windows share one family header.
///
/// Data flow:
/// Receives optional `subtitle` (e.g., the localized workspace title) and `badgeText` (e.g., the
/// marketing version string) as immutable value inputs; emits no actions.
struct LingroveSidebarBrandHeader: View {
    var subtitle: String?
    var badgeText: String?
    var topPadding: CGFloat = 12
    var bottomPadding: CGFloat = 10

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            LingroveLogoBadge(size: 26, showsGlow: true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ProductIdentity.appDisplayName)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .tracking(-0.2)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let badgeText, !badgeText.isEmpty {
                        Text(badgeText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.65), in: Capsule(style: .continuous))
                    }
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .accessibilityElement(children: .combine)
    }
}

/// Hero emblem for empty states and unselected detail canvases inside the Vocabulary notebook.
/// Pairs the squircle `LingroveLogo` with a soft ambient radial wash so empty canvases feel
/// intentionally crafted rather than like generic system placeholders.
struct LingroveBrandEmblem: View {
    var logoSize: CGFloat = 54
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            LingroveBrand.accent.opacity(colorScheme == .dark ? 0.22 : 0.14),
                            LingroveBrand.accentSoft.opacity(colorScheme == .dark ? 0.08 : 0.04),
                            .clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: logoSize * 0.95
                    )
                )
                .frame(width: logoSize * 1.8, height: logoSize * 1.8)
                .allowsHitTesting(false)

            LingroveLogoBadge(size: logoSize, showsGlow: true)
        }
        .accessibilityHidden(true)
    }
}
