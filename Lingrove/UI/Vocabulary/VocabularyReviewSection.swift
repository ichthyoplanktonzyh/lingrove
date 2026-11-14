import LingroveNotebook
import SwiftUI

/// Corpus detail owns only the send-sheet presentation. The controller and Note worker own
/// export, receipts and profile checks; no card recipe is stored inside a vocabulary sense.
struct VocabularyReviewSection: View {
    let entry: VocabularyEntry
    let sense: VocabularySense
    @ObservedObject var controller: AnkiReviewController
    var compact = false
    @State private var sendingNote = false

    var body: some View {
        HStack {
            Label("Anki", systemImage: "rectangle.stack").font(.subheadline.weight(.semibold))
            Spacer()
            Button(String(localized: "Add to Anki", table: "Vocabulary"), systemImage: "plus") {
                sendingNote = true
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(controller.noteIO == nil || controller.sendingSenseID != nil)
        }
        .padding(14)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $sendingNote) {
            VocabularyNoteAnkiSheet(controller: controller, selection: .init(entryID: entry.id, senseID: sense.id))
        }
    }
}
