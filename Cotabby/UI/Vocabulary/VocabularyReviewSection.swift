import SwiftUI

/// A sense groups independent cards. The app controller performs sends; this section owns only
/// sheet selection and deletion confirmation, so opening a card cannot create a second service.
struct VocabularyReviewSection: View {
    let entry: VocabularyEntry
    let sense: VocabularySense
    @ObservedObject var controller: AnkiReviewController
    @State private var editing: CardSelection?
    @State private var removing: VocabularyReview?
    @State private var failure: String?

    private struct CardSelection: Identifiable { let id: UUID }

    private var cards: [VocabularyReview] { sense.reviewCards ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: cards.isEmpty && failure == nil ? 0 : 10) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(cards.isEmpty ? Color.secondary : CotabbyBrand.accent)
                Text(String(localized: "Review cards", table: "Vocabulary"))
                    .font(.subheadline.weight(.semibold))
                if !cards.isEmpty {
                    Text("\(cards.count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                Spacer()
                Button { editing = .init(id: UUID()) } label: {
                    Label(String(localized: "Add card", table: "Vocabulary"), systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cards, id: \.plan.id) { card in
                        let isSynced = card.activeBinding?.noteID != nil
                        HStack(alignment: .center, spacing: 10) {
                            Circle()
                                .fill(isSynced ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(card.plan.name ?? String(localized: "Review", table: "Vocabulary"))
                                        .font(.callout.weight(.medium))
                                    Text(controller.status(entry, sense, cardID: card.plan.id))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(isSynced ? .secondary : Color.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill((isSynced ? Color.primary : Color.orange).opacity(0.07))
                                        )
                                }
                                if let layout = card.plan.layout {
                                    Text(summary(layout.front) + " → " + summary(layout.back))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button(String(localized: "Edit", table: "Vocabulary")) { editing = .init(id: card.plan.id) }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            if let binding = card.activeBinding, binding.noteID != nil {
                                Menu {
                                    Button(String(localized: "View in Anki",
                                        table: "Vocabulary")) { Task { failure = await controller.open(binding) } }
                                    Button(String(localized: "Review in Anki",
                                        table: "Vocabulary")) { Task { failure = await controller.reviewDeck(binding) } }
                                } label: {
                                    Image(systemName: "arrow.up.forward.app")
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 22, height: 22)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            Button(role: .destructive) { removing = card } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Remove local card", table: "Vocabulary"))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                        )
                    }
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5)
        )
        .disabled(controller.sendingSenseID != nil)
        .sheet(item: $editing) { selection in
            VocabularyReviewSheet(controller: controller, entry: entry, sense: sense, cardID: selection.id)
        }
        .confirmationDialog(String(localized: "Remove this card?", table: "Vocabulary"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(String(localized: "Remove local card", table: "Vocabulary"), role: .destructive) {
                    guard let card = removing else { return }; removing = nil
                    Task {
                        do { try await controller.store.removeReview(entryID: entry.id, senseID: sense.id, cardID: card.plan.id,
                            expected: card) } catch { failure = error.localizedDescription }
                    }
                }
            }
    }

    private func summary(_ parts: [ReviewCardPart]) -> String { parts.map { $0.source.label }.joined(separator: " + ") }
}
