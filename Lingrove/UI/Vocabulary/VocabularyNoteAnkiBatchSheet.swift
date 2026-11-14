import LingroveNotebook
import SwiftUI

/// Batch preparation reuses the individual review sheet for examples, preview and conflict
/// choices. The list owns queue navigation only; it never serializes notes or touches Anki itself.
struct VocabularyNoteAnkiBatchSheet: View {
    @StateObject private var batch: NoteAnkiBatchSession
    @Environment(\.dismiss) private var dismiss
    @State private var preparing: NoteAnkiBatchSession.Item?
    @State private var deck = ""
    init(controller: AnkiReviewController, selections: [VocabularySelection]) {
        _batch = StateObject(wrappedValue: NoteAnkiBatchSession(controller: controller, selections: selections))
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Batch defaults", table: "Vocabulary")) {
                    TextField(String(localized: "Deck (leave empty to keep each plan)", table: "Vocabulary"), text: $deck)
                    Button(String(localized: "Apply to selected", table: "Vocabulary")) {
                        batch.deckOverride = deck
                    }
                }.disabled(batch.busy)
                Section(String(localized: "Review cards", table: "Vocabulary")) {
                    ForEach(batch.items) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.expression).fontWeight(.semibold)
                                Text(item.meaning).font(.callout).lineLimit(2)
                                Text(status(item.status)).font(.caption).foregroundStyle(.secondary)
                                if let issue = item.message { Text(issue).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if item.status == .sending { ProgressView().controlSize(.small) }
                            Button(String(localized: "Prepare", table: "Vocabulary")) {
                                preparing = item
                            }
                                .disabled(batch.busy)
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
                        .disabled(batch.items.allSatisfy { [.synced, .unavailable].contains($0.status) })
                }
            }.padding()
        }
        .frame(width: 740, height: 720).interactiveDismissDisabled(batch.busy)
        .sheet(item: $preparing) { item in
            VocabularyNoteAnkiSheet(controller: batch.controller, selection: item.selection,
                onSent: { batch.noteSent(item.id) })
        }
        .onDisappear { batch.stop() }
    }
    private func status(_ value: NoteAnkiBatchSession.Status) -> String {
        switch value {
        case .ready: String(localized: "Ready to send", table: "Vocabulary")
        case .sending: String(localized: "Sending…", table: "Vocabulary")
        case .synced: String(localized: "Synced", table: "Vocabulary")
        case .failed: String(localized: "Send failed", table: "Vocabulary")
        case .cancelled: String(localized: "Cancelled", table: "Vocabulary")
        case .attention: String(localized: "Anki fields changed", table: "Vocabulary")
        case .unavailable: String(localized: "Not available", table: "Vocabulary")
        }
    }

}
