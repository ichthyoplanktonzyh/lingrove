import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The overview distinguishes sense participation, exercise memory and append-only records.
/// It displays shared-engine statistics instead of deriving progress from session button taps.
struct BuiltInReviewOverviewView: View {
    @ObservedObject var session: BuiltInReviewSession
    let content: NotebookBuiltInReviewSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(BuiltInReviewCopy.text("nav.overview")).font(.largeTitle.weight(.semibold))
                Text(BuiltInReviewCopy.text("description.overview")).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    metric("count.activeSenses", content.statistics.activeSenses)
                    metric("count.exercises", content.statistics.exercises)
                    metric("count.ready", content.statistics.readyExercises)
                }
                HStack {
                    Button(BuiltInReviewCopy.text("action.start"), systemImage: "play.fill") { session.start() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(session.isBusy || content.queue.isEmpty)
                        .accessibilityIdentifier("builtinReview.start")
                    if content.queue.isEmpty {
                        Text(BuiltInReviewCopy.text(content.review.groups.isEmpty ? "state.noSelection" : "state.noReady"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                GroupBox(BuiltInReviewCopy.text("progress.title")) {
                    VStack(spacing: 9) {
                        row("count.new", content.statistics.newExercises)
                        row("count.reviewed", content.statistics.reviewedExercises)
                        row("count.paused", content.statistics.pausedSenses)
                        row("count.withdrawn", content.statistics.withdrawnSenses)
                        Divider()
                        row("count.ratings", content.statistics.ratingRecords)
                        row("count.undos", content.statistics.undoneRatings)
                    }.padding(8)
                }
                Text(BuiltInReviewCopy.text("description.history")).font(.caption).foregroundStyle(.secondary)
                if !content.recentHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(BuiltInReviewCopy.text("history.title")).font(.headline)
                        ForEach(content.recentHistory) { event in
                            HStack(alignment: .top) {
                                Text(BuiltInReviewCopy.rating(event.rating)).frame(width: 80, alignment: .leading)
                                Text(historyTitle(event)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                if event.wasUndone { Text(BuiltInReviewCopy.text("history.undone")).foregroundStyle(.secondary) }
                                if let date = parseIsoTimestamp(value: event.reviewedAt) {
                                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .foregroundStyle(.secondary)
                                }
                            }.font(.callout)
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading)
        }.accessibilityIdentifier("builtinReview.overview.content")
    }

    private func metric(_ key: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value, format: .number).font(.system(.largeTitle, design: .rounded).weight(.semibold))
            Text(BuiltInReviewCopy.text(key)).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ key: String, _ count: Int) -> some View {
        LabeledContent(BuiltInReviewCopy.text(key)) { Text(count, format: .number).monospacedDigit() }
    }

    private func historyTitle(_ history: NotebookBuiltInReviewHistory) -> String {
        guard let group = content.review.groups.values.first(where: { $0.cards.contains { $0.cardId == history.cardID } }) else {
            return BuiltInReviewCopy.text("history.savedExercise")
        }
        return BuiltInReviewSource.value(group.selection, in: content.scope)?.entry.expression
            ?? BuiltInReviewCopy.text("history.savedExercise")
    }
}

/// Choosing a saved sense opens its details. This sheet intentionally has no enrollment writer;
/// the person confirms the separate Add to review action after inspecting that sense's material.
struct BuiltInReviewSenseChooser: View {
    let content: NotebookBuiltInReviewSnapshot
    let onSelect: (VocabularySelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(BuiltInReviewCopy.text("action.choose")).font(.title2.weight(.semibold))
            Text(BuiltInReviewCopy.text("description.choose")).foregroundStyle(.secondary)
            TextField(BuiltInReviewCopy.text("field.search"), text: $search).textFieldStyle(.roundedBorder)
            List {
                ForEach(content.scope.document.collectedEntries) { entry in
                    ForEach(entry.senses.filter { matches(entry.expression, $0.meaning) }) { sense in
                        Button { onSelect(.init(entryID: entry.id, senseID: sense.id)) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.expression).font(.headline)
                                Text(sense.meaning).foregroundStyle(.secondary).lineLimit(3)
                                Text(content.review.groups[sense.id].map { BuiltInReviewCopy.status($0.status) }
                                    ?? BuiltInReviewCopy.text("status.notSelected")).font(.caption)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                }
            }.overlay {
                if content.scope.document.collectedEntries.isEmpty {
                    ContentUnavailableView(BuiltInReviewCopy.text("state.noCorpus"), systemImage: "books.vertical")
                }
            }
            HStack { Spacer(); Button(BuiltInReviewCopy.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 560, height: 520)
    }

    private func matches(_ expression: String, _ meaning: String) -> Bool {
        search.isEmpty || expression.localizedCaseInsensitiveContains(search) || meaning.localizedCaseInsensitiveContains(search)
    }
}
