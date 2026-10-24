import SwiftUI

/// An unassigned key is visible as such. Both states lead to the existing central Shortcuts
/// pane, so the guide never presents a separate shortcut editor or invents a default binding.
struct CurrentShortcutRow: View {
    let title: String
    let isBound: Bool
    let label: String
    let open: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer(minLength: 12)
            Button(action: open) {
                Text(isBound ? label : String(localized: "Not assigned", table: "Learning")).font(.subheadline.monospaced())
            }.buttonStyle(.borderless).help(String(localized: "Shortcuts"))
                .accessibilityLabel(title)
                .accessibilityValue(isBound ? label : String(localized: "Not assigned", table: "Learning"))
        }
    }
}
