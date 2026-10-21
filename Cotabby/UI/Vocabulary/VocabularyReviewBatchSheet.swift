import SwiftUI

/// Batch preparation reuses the individual review sheet for examples, preview and conflict
/// choices. The list owns queue navigation only; it never serializes notes or touches Anki itself.
struct VocabularyReviewBatchSheet: View {
    @StateObject private var batch: AnkiReviewBatchSession
    @Environment(\.dismiss) private var dismiss
    @State private var preparing: ReviewBatchItem?
    @State private var deck = ""
    init(controller: AnkiReviewController, selections: [VocabularySelection]) {
        _batch = StateObject(wrappedValue: AnkiReviewBatchSession(controller: controller, selections: selections, flexible: true))
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Batch defaults", table: "Vocabulary")) {
                    TextField(String(localized: "Deck (leave empty to keep each plan)", table: "Vocabulary"), text: $deck)
                    Button(String(localized: "Apply to selected", table: "Vocabulary")) {
                        batch.startApply(deck: deck, cards: 0, audio: 0)
                    }
                }.disabled(batch.busy)
                Section(String(localized: "Review cards", table: "Vocabulary")) {
                    if batch.emptySenseCount > 0 {
                        Text(String(localized: "Some selected senses have no cards. Add cards in the notebook first.", table: "Vocabulary"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(batch.items) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.expression).fontWeight(.semibold)
                                Text(item.meaning).font(.callout).lineLimit(2)
                                Text(item.status.label).font(.caption).foregroundStyle(.secondary)
                                if let issue = item.message { Text(issue).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if item.status == .sending { ProgressView().controlSize(.small) }
                            Button(String(localized: "Prepare", table: "Vocabulary")) {
                                batch.beginPreparation(item.id); preparing = item
                            }
                                .disabled(batch.busy || batch.resolve(item) == nil)
                            if [.failed, .cancelled, .attention].contains(item.status) {
                                Button(String(localized: "Retry", table: "Vocabulary")) { batch.start(only: item.id) }
                                    .disabled(batch.busy)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if let message = batch.message { Section { Text(message).foregroundStyle(.red) } }
            }.formStyle(.grouped)
            HStack {
                Text("\(batch.completeCount) / \(batch.items.count)").font(.caption).monospacedDigit()
                Spacer()
                if batch.busy { Button(String(localized: "Stop", table: "Vocabulary")) { batch.stop() } } else {
                    Button(String(localized: "Close", table: "Vocabulary")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(String(localized: "Send remaining", table: "Vocabulary")) { batch.start() }
                        .disabled(batch.items.allSatisfy { [.synced, .skipped, .unavailable].contains($0.status) })
                }
            }.padding()
        }
        .frame(width: 740, height: 720).interactiveDismissDisabled(batch.busy)
        .sheet(item: $preparing) { item in
            if let (entry, sense) = batch.resolve(item) {
                VocabularyReviewSheet(controller: batch.controller, entry: entry, sense: sense, cardID: item.cardID)
                    .onDisappear { batch.refresh(item.id) }
            }
        }
        .onDisappear { batch.stop() }
    }
}
