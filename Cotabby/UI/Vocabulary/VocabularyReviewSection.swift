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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Review cards", table: "Vocabulary")).font(.headline)
                Spacer()
                Button { editing = .init(id: UUID()) } label: {
                    Label(String(localized: "Add card", table: "Vocabulary"), systemImage: "plus")
                }
            }
            ForEach(sense.reviewCards ?? [], id: \.plan.id) { card in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.plan.name ?? String(localized: "Review", table: "Vocabulary")).fontWeight(.medium)
                        if let layout = card.plan.layout {
                            Text(summary(layout.front) + " → " + summary(layout.back)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(controller.status(entry, sense, cardID: card.plan.id)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "Edit", table: "Vocabulary")) { editing = .init(id: card.plan.id) }
                    if let binding = card.activeBinding, binding.noteID != nil {
                        Menu {
                            Button(String(localized: "View in Anki",
                                table: "Vocabulary")) { Task { failure = await controller.open(binding) } }
                            Button(String(localized: "Review in Anki",
                                table: "Vocabulary")) { Task { failure = await controller.reviewDeck(binding) } }
                        } label: { Image(systemName: "arrow.up.forward.app") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    Button(role: .destructive) { removing = card } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help(String(localized: "Remove local card", table: "Vocabulary"))
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
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
