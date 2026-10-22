import SwiftUI

/// File overview:
/// One Home quick-link card: an icon tile, a title, a one-line caption, and a chevron that walks
/// in on hover. The whole card is a button that opens its pane. Hover lift is kept subtle (a
/// hairline tint and a 1pt rise, no scaling) so a grid stays calm as new destinations are added.
struct SettingsQuickLinkCard: View {
    let title: String
    let caption: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    init(category: SettingsCategory, action: @escaping () -> Void) {
        self.init(title: category.label, caption: category.summary, systemImage: category.systemImage,
            tint: category.tint, action: action)
    }

    init(title: String, caption: String, systemImage: String, tint: Color, action: @escaping () -> Void) {
        self.title = title; self.caption = caption; self.systemImage = systemImage; self.tint = tint; self.action = action
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: systemImage, tint: tint, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
                    .offset(x: isHovering ? 0 : -4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isHovering ? tint.opacity(0.35) : Color.primary.opacity(0.07),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(isHovering ? 0.10 : 0.04),
                radius: isHovering ? 6 : 2,
                y: isHovering ? 3 : 1
            )
            .offset(y: isHovering ? -1 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel("\(title) settings")
        .accessibilityHint(caption)
    }
}

/// The five existing learning tabs supply Home's destinations and Help's familiar icons. This
/// metadata describes navigation only; visiting a quick link never enables a feature.
extension SettingsLearningTask {
    var quickLinkSymbol: String {
        switch self {
        case .translation: "character.bubble"
        case .explanation: "sparkles"
        case .readAloud: "speaker.wave.2"
        case .dictionary: "book.closed"
        case .review: "rectangle.stack"
        }
    }
    var quickLinkCaption: String {
        switch self {
        case .translation: String(localized: "Translation previews and reading sources.", table: "Learning")
        case .explanation: String(localized: "Contextual meanings and explanations.", table: "Learning")
        case .readAloud: String(localized: "Voices and speaking speed.", table: "Learning")
        case .dictionary: String(localized: "Dictionary sources and lookup.", table: "Learning")
        case .review: String(localized: "Anki and review cards.", table: "Learning")
        }
    }
}
