import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// This native sheet reads the same append-only records as the app-owned review session. It
/// displays historical and undone ratings separately and returns the exact displayed undo
/// identity to that session; the view creates no separate statistics or write authority.
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
                    if content.recentHistory.isEmpty {
                        Text(BuiltInReviewCopy.text("history.empty")).foregroundStyle(.secondary)
                    }
                    ForEach(content.recentHistory) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            let group = content.review.groups.values.first { $0.cards.contains { $0.cardId == event.cardID } }
                            let source = group.flatMap { BuiltInReviewSource.value($0.selection, in: content.scope) }
                            let card = group?.cards.first { $0.cardId == event.cardID }
                            Text(source?.entry.expression ?? card?.frontText ?? BuiltInReviewCopy.text("history.savedExercise"))
                                .fontWeight(.semibold).lineLimit(2)
                            if let meaning = source?.sense.meaning {
                                Text(meaning).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            if source == nil {
                                Text(BuiltInReviewCopy.text("state.missingSource")).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Label(BuiltInReviewCopy.rating(event.rating), systemImage: event.rating.symbolName)
                                    .fontWeight(.semibold).foregroundStyle(lingroveReviewRatingColor(event.rating))
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
                }
            }.navigationTitle(BuiltInReviewCopy.text("history.title"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Close", table: "ReviewCards")) { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 440, idealHeight: 520)
        .accessibilityIdentifier("builtinReview.historySheet")
    }
}
