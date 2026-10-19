import SwiftUI

/// An inline disclosure for whole native Form sections. Sections stay siblings of the header:
/// nesting them inside a DisclosureGroup changes macOS grouped-form layout and scrolling anchors.
/// The Settings navigation owner retains expansion per task; no durable model preference changes.
struct SettingsAdvancedSections<Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section {
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    Text(String(localized: "Advanced settings", table: "Learning"))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? String(localized: "Expanded", table: "Learning")
                : String(localized: "Collapsed", table: "Learning"))
        }
        if isExpanded { content() }
    }
}
