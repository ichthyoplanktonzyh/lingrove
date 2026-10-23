import SwiftUI

/// An inline disclosure for whole native Form sections. Sections stay siblings of the header:
/// nesting them inside a DisclosureGroup changes macOS grouped-form layout and scrolling anchors.
/// The Settings navigation owner retains expansion per task; no durable model preference changes.
struct SettingsAdvancedSections<Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Section {
            Button {
                withAnimation(SettingsMotion.resolved(SettingsMotion.disclosure, reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .center)
                        .accessibilityHidden(true)

                    Text(String(localized: "Advanced settings", table: "Learning"))
                        .fontWeight(.medium)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHovering ? .primary : .secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(SettingsMotion.resolved(SettingsMotion.interaction, reduceMotion: reduceMotion)) {
                    isHovering = hovering
                }
            }
            .accessibilityValue(isExpanded ? String(localized: "Expanded", table: "Learning")
                : String(localized: "Collapsed", table: "Learning"))
        }
        if isExpanded {
            content()
        }
    }
}
