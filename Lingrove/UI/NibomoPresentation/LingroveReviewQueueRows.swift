// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W3_UI_REUSE_MAP.md.
import SwiftUI
import LingroveNotebookEngine

private let reviewCardsStringsTableName = "ReviewCards"

/// Extracted Nibomo queue row. Its parent supplies a frozen shared-engine Card and current flag.
struct LingroveReviewQueuePreviewCardRow: View {
    let card: Card
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(card.frontText)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isCurrent {
                    Text(String(localized: "Current", table: reviewCardsStringsTableName))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.tint.opacity(0.14))
                        )
                }
            }

            Text(card.backText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 12) {
                Label(localizedDueDateLabel(value: card.dueAt), systemImage: "clock")
                Label(card.tags.isEmpty ? String(localized: "No tags", table: "ReviewCards")
                    : card.tags.joined(separator: ", "), systemImage: "tag")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    .tint.opacity(isCurrent ? 0.35 : 0),
                    lineWidth: 1
                )
        }
    }
}

/// Divider for scheduled items after the active queue, as in Nibomo’s preview.
struct LingroveReviewQueueSectionSeparator: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1)

            Text(String(localized: "Later", table: reviewCardsStringsTableName))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

private func localizedDueDateLabel(value: String?) -> String {
    guard let value else {
        return String(localized: "New", table: reviewCardsStringsTableName)
    }

    guard let date = parseIsoTimestamp(value: value) else {
        return value
    }

    return date.formatted(date: .abbreviated, time: .shortened)
}
