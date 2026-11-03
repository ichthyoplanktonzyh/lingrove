import LingroveNotebook
import SwiftUI

/// The Anki adapter translates its export plan into the same material model the built-in
/// sheet edits. Decks, bindings, conflicts and network state never enter the shared editor.
struct VocabularyReviewLayoutEditor: View {
    @ObservedObject var session: AnkiReviewSession
    @ObservedObject var store: VocabularyStore
    @Binding var operation: Task<Void, Never>?
    var hostedSide: Binding<Bool>?
    var previewFirst = false

    private var material: Binding<ReviewMaterialPlan> {
        Binding(get: { session.materialPlan }, set: { session.materialPlan = $0 })
    }

    var body: some View {
        if let source = session.current {
            ReviewMaterialEditor(plan: material, entry: source.entry, sense: source.sense, store: store,
                scope: session.notebookScope, importedImages: $session.importedImages,
                importingImage: $session.importingImage, operation: $operation,
                hostedSide: hostedSide, previewFirst: previewFirst,
                prepareAudio: { await session.prepareAudio($0, audition: true) })
        }
    }
}
