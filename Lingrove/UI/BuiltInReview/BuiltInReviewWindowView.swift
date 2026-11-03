import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The existing window borrows one app-owned session. This root binds Nibomo’s review column,
/// filter/header and queue sheets to that session; it never constructs a mobile store or owns
/// account/sync services. Sheet choices remain navigation until an explicit enrollment command.
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
                }.font(.callout).padding(12).background(.quaternary)
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
        // Color scheme is a subtree value: preferredColorScheme would change the hosting
        // window, including the untouched corpus/sidebar when this view is embedded.
        .tint(.orange).environment(\.colorScheme, .dark)
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $choosingSense) {
            if let content = session.content {
                BuiltInReviewSenseChooser(content: content) { selection in
                    choosingSense = false
                    session.endPractice()
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

    /// Mirrors ReviewView.reviewCompanionHeader: filter left, centered title, trailing actions.
    /// Lingrove’s sense participation replaces the mobile Deck filter, leaving its structure intact.
    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if session.route == .practice {
                    Button(BuiltInReviewCopy.text("action.finish")) { session.endPractice() }
                        .accessibilityIdentifier("builtinReview.finish")
                } else {
                    Button {
                        if session.content?.queue.isEmpty == false { session.start() } else { session.endPractice() }
                    } label: { Image(systemName: "chevron.left") }
                        .help(String(localized: "Review", table: "ReviewCards"))
                }
                Button { choosingSense = true } label: {
                    Label(BuiltInReviewCopy.text("nav.selected"), systemImage: "line.3.horizontal.decrease")
                }.lingroveNativeActionButtonStyle().accessibilityIdentifier("builtinReview.choose")
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "Review", table: "ReviewCards"))
                .font(.headline).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity).accessibilityAddTraits(.isHeader)
            HStack(spacing: 14) {
                if session.isBusy { ProgressView().controlSize(.small) }
                if let undo = session.latestUndo {
                    Button { session.undo(undo) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help(BuiltInReviewCopy.text("action.undo")).accessibilityIdentifier("builtinReview.session.undo")
                }
                Button { showingQueue = true } label: { Image(systemName: "list.bullet") }
                    .help(String(localized: "Review", table: "ReviewCards"))
                    .accessibilityIdentifier("builtinReview.queue")
                Button { showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help(BuiltInReviewCopy.text("history.title"))
                Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help(BuiltInReviewCopy.text("action.refresh"))
            }.buttonStyle(.plain).font(.title3).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(.horizontal, 20).padding(.vertical, 14)
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
