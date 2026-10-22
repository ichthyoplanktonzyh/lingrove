import SwiftUI

/// A captioned "mock text field" panel. Mirrors the onboarding `PermissionCard` look (regular
/// material plus a hairline stroke) at a tighter corner radius. The content area is pinned to a fixed
/// height so a card whose inner popup appears and disappears never changes the window's height.
struct OnboardingDemoCard<Content: View>: View {
    let caption: String
    let contentHeight: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            content
                .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight, alignment: .topLeading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                )
        }
    }
}
