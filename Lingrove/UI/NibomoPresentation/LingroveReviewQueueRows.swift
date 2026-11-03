// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_REVIEW_ACCOUNT_UI_REUSE.md.
import SwiftUI
import LingroveNotebookEngine

private let reviewCardsStringsTableName = "ReviewCards"

/// A read-only native queue card receives a frozen engine Card and current flag from its parent.
/// Source text remains selectable; status uses a written badge as well as the inherited accent.
struct LingroveReviewQueuePreviewCardRow: View {
    let card: Card
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(card.frontText)
                    .font(.headline)
                    .textSelection(.enabled)
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
                .textSelection(.enabled)
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isCurrent ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.45),
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
