import SwiftUI

/// Both the visible padding and the text belong to one button. A plain SwiftUI button's
/// transparent label can otherwise accept only glyph hits, despite looking like a menu row.
struct DictionarySourceRow: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).lineLimit(2)
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor).opacity(selected ? 1 : 0)
                    .frame(width: 16)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DictionarySourceButtonStyle(hovering: hovering, selected: selected))
        .onHover { hovering = $0 }
    }
}

/// A shared, size-neutral highlight keeps the selector and its options visually related.
struct DictionarySourceButtonStyle: ButtonStyle {
    var hovering = false
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background {
            RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(
                configuration.isPressed ? 0.24 : (hovering ? 0.14 : (selected ? 0.08 : 0))))
        }
    }
}
