import LingroveNotebookEngine
import SwiftUI

/// History is an additional Lingrove business surface because Nibomo’s whole Progress tab is
/// outside this extraction. It reads the same append-only engine records and sends the exact
/// displayed undo identity back to the session; no view-maintained progress ledger is created.
struct BuiltInReviewHistoryView: View {
    @ObservedObject var session: BuiltInReviewSession
    let content: NotebookBuiltInReviewSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(BuiltInReviewCopy.text("progress.title")) {
                    LabeledContent(BuiltInReviewCopy.text("count.ratings"), value: content.statistics.ratingRecords.formatted())
                    LabeledContent(BuiltInReviewCopy.text("count.undos"), value: content.statistics.undoneRatings.formatted())
                }
                Section(BuiltInReviewCopy.text("history.title")) {
                    ForEach(content.recentHistory) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(BuiltInReviewCopy.rating(event.rating)).fontWeight(.semibold)
                                Spacer()
                                if event.wasUndone { Text(BuiltInReviewCopy.text("history.undone")).foregroundStyle(.secondary) }
                                if let undo = session.undoAction(cardID: event.cardID, basedOn: content),
                                   content.recentHistory.first(where: { $0.cardID == event.cardID })?.id == event.id {
                                    Button(BuiltInReviewCopy.text("action.undo")) { session.undo(undo); dismiss() }
                                        .disabled(session.isBusy)
                                }
                            }
                            if let date = parseIsoTimestamp(value: event.reviewedAt) {
                                Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(BuiltInReviewCopy.text("description.history")).font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle(BuiltInReviewCopy.text("history.title"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Close", table: "ReviewCards")) { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
        }.frame(width: 620, height: 520).preferredColorScheme(.dark).tint(.orange)
    }
}
