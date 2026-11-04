import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The source detail borrows the one review session for a scoped participation read. Its single
/// action navigates to real material management, while Anki's sibling section keeps its own
/// enrollment/export state. An ordinary corpus save never calls a review writer.
struct VocabularyBuiltInReviewSection: View {
    let entry: VocabularyEntry
    let sense: VocabularySense
    @ObservedObject var store: VocabularyStore
    @ObservedObject var session: BuiltInReviewSession
    @State private var status: LingroveNotebookReviewStatus?
    @State private var exerciseCount = 0
    @State private var unavailable = false
    @State private var loaded = false
    @State private var failed = false
    @State private var joining = false
    @State private var failure: String?

    private var selection: VocabularySelection { .init(entryID: entry.id, senseID: sense.id) }
    private var statusText: String {
        if failed { return BuiltInReviewCopy.text("state.unavailable") }
        if !loaded { return BuiltInReviewCopy.text("state.loading") }
        if unavailable { return BuiltInReviewCopy.text("material.unavailable") }
        return status.map(BuiltInReviewCopy.status) ?? BuiltInReviewCopy.text("status.notSelected")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lingrove").font(.subheadline.weight(.semibold))
                Text(failure ?? statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(BuiltInReviewCopy.text(exerciseCount > 0 ? "nav.content" : "action.enroll")) {
                if exerciseCount > 0 { store.onRequestBuiltInReview?(selection) } else {
                    joining = true
                    Task { failure = await session.enrollFromCorpus(selection); joining = false }
                }
            }.buttonStyle(.bordered).controlSize(.small).disabled(joining || session.isBusy)
                .accessibilityIdentifier("vocabulary.review.lingrove.manage")
        }.padding(14).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5) }
            .task(id: sense.id.uuidString + store.scopeIdentity.uuidString + session.participationRevision.uuidString) {
                loaded = false; failed = false
                do {
                    let content = try await session.inspectParticipation()
                    try Task.checkCancellation()
                    let group = content.review.groups[sense.id]
                    status = group?.status
                    exerciseCount = group?.cards.count ?? 0
                    unavailable = group?.hasUnavailableMaterial == true
                    loaded = true
                } catch is CancellationError { } catch { failed = true; loaded = true }
            }
            .accessibilityIdentifier("vocabulary.review.lingrove")
    }
}
