import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The workspace borrows one app-owned session. This root owns only destination chrome and
/// transient sheets; the session continues to own the pinned question, writer and source links.
/// Appearance is inherited from the native host so a sheet and its parent resolve together.
struct BuiltInReviewWindowView: View {
    @ObservedObject var session: BuiltInReviewSession
    @State private var choosingSense = false
    @State private var showingQueue = false
    @State private var showingHistory = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = session.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(BuiltInReviewCopy.text("action.refresh")) { session.reload() }.disabled(session.isBusy)
                }
                .font(.callout).padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityIdentifier("builtinReview.message")
            }
            if let content = session.content {
                destination(content).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(BuiltInReviewCopy.text(session.isRefreshing ? "state.loading" : "state.unavailable"),
                          systemImage: session.isRefreshing ? "hourglass" : "exclamationmark.triangle")
                } description: { Text(BuiltInReviewCopy.text("description.offline")) }
                actions: {
                    if session.isRefreshing { ProgressView() } else {
                        Button(BuiltInReviewCopy.text("action.refresh")) { session.reload() }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 500)
        .sheet(isPresented: $choosingSense) {
            if let content = session.content {
                BuiltInReviewSenseChooser(content: content) { selection in
                    choosingSense = false
                    // Choosing material is navigation. Ending a practice has its own visible
                    // action, and the chooser is unavailable while that practice is on screen.
                    session.route = .sense(selection)
                }
            }
        }
        .sheet(isPresented: $showingQueue) {
            if let content = session.content {
                BuiltInReviewQueuePreviewView(content: content, currentCardID: session.practice?.phase.context?.card.cardId)
            }
        }
        .sheet(isPresented: $showingHistory) {
            if let content = session.content { BuiltInReviewHistoryView(session: session, content: content) }
        }
        .sheet(item: $session.draft) { draft in BuiltInReviewPreparationView(session: session, draft: draft) }
        .accessibilityIdentifier("builtinReview.window")
    }

    /// Titles use the same native hierarchy as Progress. At narrow widths the action row wraps
    /// as a unit instead of squeezing the title or hiding the explicit end-practice action.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                heading
                Spacer(minLength: 16)
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                heading
                actions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var heading: some View {
        HStack(spacing: 12) {
            if case .sense = session.route {
                Button { session.route = .overview } label: {
                    Label(BuiltInReviewCopy.text("nav.overview"), systemImage: "chevron.left")
                }
                .help(BuiltInReviewCopy.text("nav.overview"))
                .accessibilityIdentifier("builtinReview.back")
                .disabled(session.isBusy)
            }
            Text(String(localized: "Review", table: "ReviewCards"))
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if session.isBusy { ProgressView().controlSize(.small) }
            if session.route == .practice {
                Button(BuiltInReviewCopy.text("action.endPractice")) { session.endPractice() }
                    .accessibilityIdentifier("builtinReview.finish")
            } else {
                Button { choosingSense = true } label: {
                    Label(BuiltInReviewCopy.text("nav.selected"), systemImage: "line.3.horizontal.decrease")
                }
                .accessibilityIdentifier("builtinReview.choose")
            }
            if let undo = session.latestUndo {
                Button { session.undo(undo) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(BuiltInReviewCopy.text("action.undo"))
                    .accessibilityLabel(BuiltInReviewCopy.text("action.undo"))
                    .accessibilityIdentifier("builtinReview.session.undo")
            }
            Button { showingQueue = true } label: { Image(systemName: "list.bullet") }
                .help(BuiltInReviewCopy.text("queue.title"))
                .accessibilityLabel(BuiltInReviewCopy.text("queue.title"))
                .accessibilityIdentifier("builtinReview.queue")
            Button { showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .help(BuiltInReviewCopy.text("history.title"))
                .accessibilityLabel(BuiltInReviewCopy.text("history.title"))
                .accessibilityIdentifier("builtinReview.history")
            Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help(BuiltInReviewCopy.text("action.refresh"))
                .accessibilityLabel(BuiltInReviewCopy.text("action.refresh"))
                .accessibilityIdentifier("builtinReview.refresh")
        }
        .buttonStyle(.bordered).controlSize(.regular)
        .disabled(session.isBusy || session.content == nil)
    }

    @ViewBuilder private func destination(_ content: NotebookBuiltInReviewSnapshot) -> some View {
        switch session.route {
        case .overview: BuiltInReviewOverviewView(session: session, content: content)
        case let .sense(selection): BuiltInReviewSenseView(session: session, selection: selection, content: content)
        case .practice: BuiltInReviewPracticeView(session: session, content: content)
        }
    }
}

/// Label/navigation projection only. The actual enrollment and Card source keep their frozen
/// identity, so a moved example or renamed expression cannot silently retarget a practice record.
enum BuiltInReviewSource {
    static func value(_ selection: VocabularySelection, in scope: LingroveNotebookSnapshot)
        -> (entry: VocabularyEntry, sense: VocabularySense)? {
        for entry in scope.document.entries {
            if let sense = entry.senses.first(where: { $0.id == selection.senseID || $0.mergedFrom.contains(selection.senseID) }) {
                return (entry, sense)
            }
        }
        return nil
    }
}
