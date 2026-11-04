import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The workspace borrows one app-owned session. This root owns only destination chrome and
/// transient sheets; the session continues to own the pinned question, writer and source links.
/// Appearance is inherited from the native host so a sheet and its parent resolve together.
struct BuiltInReviewWindowView: View {
    @ObservedObject var session: BuiltInReviewSession
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
                } actions: {
                    if session.isRefreshing { ProgressView() } else {
                        Button(BuiltInReviewCopy.text("action.refresh")) { session.reload() }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 500)
        .sheet(isPresented: $showingQueue) {
            if let content = session.content {
                BuiltInReviewQueuePreviewView(content: content, currentCardID: session.practice?.phase.context?.card.cardId)
            }
        }
        .sheet(isPresented: $showingHistory) {
            if let content = session.content { BuiltInReviewHistoryView(session: session, content: content) }
        }
        .sheet(item: $session.batchDraft) { batch in BuiltInReviewBatchView(session: session, batch: batch) }
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
            if isDetail || session.route == .adding {
                Button { session.route = isDetail ? session.browsing.detailOrigin : .content } label: {
                    Label(BuiltInReviewCopy.text(isDetail && session.browsing.detailOrigin == .adding
                        ? "action.addContent" : "nav.content"), systemImage: "chevron.left")
                }
                .help(BuiltInReviewCopy.text("nav.content"))
                .accessibilityIdentifier("builtinReview.back")
                .disabled(session.isBusy)
            }
            if session.route == .overview || session.route == .content {
                Picker(BuiltInReviewCopy.text("nav.lingrove"), selection: $session.route) {
                    Text(BuiltInReviewCopy.text("nav.today")).tag(BuiltInReviewRoute.overview)
                    Text(BuiltInReviewCopy.text("nav.content")).tag(BuiltInReviewRoute.content)
                }.pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("builtinReview.navigation")
            } else {
                Text(pageTitle)
                    .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            }
        }
    }

    private var isDetail: Bool { if case .sense = session.route { return true }; return false }

    private var pageTitle: String {
        if session.route == .adding { return BuiltInReviewCopy.text("action.addContent") }
        if case let .sense(selection) = session.route, let content = session.content {
            return BuiltInReviewSource.value(selection, in: content.scope)?.entry.expression ?? BuiltInReviewCopy.text("nav.content")
        }
        return BuiltInReviewCopy.text("nav.practice")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if session.isBusy { ProgressView().controlSize(.small) }
            if session.route == .practice, session.practice?.phase.context != nil {
                Button(BuiltInReviewCopy.text("action.endPractice")) { session.endPractice() }
                    .accessibilityIdentifier("builtinReview.finish")
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
        case .content, .adding:
            VStack(spacing: 0) {
                if session.addedCount > 0 {
                    HStack {
                        Label(BuiltInReviewCopy.text("message.added"), systemImage: "checkmark.circle")
                        Text(session.addedCount.formatted()).monospacedDigit()
                        Spacer()
                        Button(BuiltInReviewCopy.text("action.start")) { session.start() }.disabled(content.queue.isEmpty)
                    }.padding(16)
                }
                BuiltInReviewContentView(content: content, browsing: $session.browsing,
                    adding: session.route == .adding, onAdd: session.showAdding,
                    onEnroll: session.requestBatch, onSelect: session.showDetail)
            }.disabled(session.isBusy)
        case let .sense(selection): BuiltInReviewSenseView(session: session, selection: selection, content: content)
        case .practice: BuiltInReviewPracticeView(session: session, content: content)
        }
    }
}
