import SwiftUI

/// A compact sense-scoped action row leaves the existing favorite and toolbar intact. The
/// library supplies immutable source values; the sheet borrows the same app-owned controller.
struct VocabularyReviewSection: View {
    let entry: VocabularyEntry
    let sense: VocabularySense
    @ObservedObject var controller: AnkiReviewController
    @State private var showingSheet = false
    @State private var openError: String?

    var body: some View {
        HStack(spacing: 10) {
            Button(buttonLabel) { showingSheet = true }
            if controller.sendingSenseID == sense.id { ProgressView().controlSize(.small) }
            Text(controller.status(entry, sense)).font(.caption).foregroundStyle(.secondary)
            if let binding = sense.review?.activeBinding, let synced = binding.syncedAt, binding.noteID != nil {
                Text(synced, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.tertiary)
                Button(String(localized: "View in Anki", table: "Vocabulary")) {
                    Task { openError = await controller.open(binding) }
                }
                    .buttonStyle(.link)
                Button(String(localized: "Review in Anki", table: "Vocabulary")) {
                    Task { openError = await controller.reviewDeck(binding) }
                }.buttonStyle(.link)
            }
        }
        .disabled(controller.sendingSenseID != nil)
        .sheet(isPresented: $showingSheet) { VocabularyReviewSheet(controller: controller, entry: entry, sense: sense) }
        .alert(String(localized: "Anki connection", table: "Vocabulary"), isPresented: Binding(
            get: { openError != nil }, set: { if !$0 { openError = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { openError = nil }
            } message: { Text(openError ?? "") }
    }
    private var buttonLabel: String {
        sense.review?.activeBinding?.noteID == nil ? String(localized: "Add to Anki", table: "Vocabulary")
            : String(localized: "Update Anki", table: "Vocabulary")
    }
}
