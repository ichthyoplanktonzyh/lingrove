import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The confirmation borrows a frozen batch from the app-owned session. Cancel releases only
/// that value; Add submits one atomic command, and a write failure leaves the same retry IDs.
struct BuiltInReviewBatchView: View {
    @ObservedObject var session: BuiltInReviewSession
    let batch: BuiltInReviewBatchDraft

    var body: some View {
        NavigationStack {
            List(batch.drafts) { draft in
                let source = BuiltInReviewSource.value(draft.selection, in: draft.snapshot)
                VStack(alignment: .leading, spacing: 5) {
                    Text(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource")).fontWeight(.semibold)
                    Text(source?.sense.meaning ?? "").foregroundStyle(.secondary)
                    Text(batch.content.review.groups[draft.selection.senseID].map { BuiltInReviewCopy.status($0.status) }
                        ?? BuiltInReviewCopy.text("status.notSelected")).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
            }
            .safeAreaInset(edge: .bottom) {
                if let message = session.message { Text(message).foregroundStyle(.red).padding() }
            }
            .navigationTitle(BuiltInReviewCopy.text("batch.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(BuiltInReviewCopy.text("action.cancel")) { session.batchDraft = nil }
                        .keyboardShortcut(.cancelAction).disabled(session.isMutating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if session.isMutating { ProgressView().controlSize(.small) }
                    Button(BuiltInReviewCopy.text("batch.enroll")) { session.saveBatch(batch) }
                        .disabled(session.isBusy).accessibilityIdentifier("builtinReview.batch.save")
                }
            }
        }.frame(minWidth: 540, idealWidth: 620, minHeight: 400, idealHeight: 520)
            .interactiveDismissDisabled(session.isMutating).accessibilityIdentifier("builtinReview.batch")
    }
}
