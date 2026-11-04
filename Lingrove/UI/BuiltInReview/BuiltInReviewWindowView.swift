import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The workspace borrows one app-owned session. This root owns only destination chrome and
/// transient sheets; the session continues to own the pinned question, writer and source links.
/// Appearance is inherited from the native host so a sheet and its parent resolve together.
struct BuiltInReviewWindowView: View {
    @ObservedObject var session: BuiltInReviewSession
    var targetNavigation: NotebookReviewDestinationModel?
    @State private var showingQueue = false
    @State private var showingHistory = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if let message = session.message {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(LingroveBrand.accent)
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(BuiltInReviewCopy.text("action.refresh")) { session.reload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(session.isBusy)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(LingroveBrand.accent.opacity(0.08))
                .overlay(alignment: .bottom) { Divider().opacity(0.4) }
                .accessibilityIdentifier("builtinReview.message")
            }
            if let content = session.content, let index = session.browserIndex {
                destination(content, index: index).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(BuiltInReviewCopy.text(session.isRefreshing ? "state.loading" : "state.unavailable"),
                          systemImage: session.isRefreshing ? "hourglass" : "exclamationmark.triangle")
                } actions: {
                    if session.isRefreshing { ProgressView() } else {
                        Button(BuiltInReviewCopy.text("action.refresh")) { session.reload() }
                            .buttonStyle(.bordered)
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
        .sheet(item: $session.noteDraft) { draft in ReviewNoteEditor(session: session, draft: draft) }
        .sheet(item: $session.noteTypeDraft) { draft in ReviewNoteTypeEditor(session: session, draft: draft) }
        .sheet(item: $session.draft) { draft in BuiltInReviewPreparationView(session: session, draft: draft) }
        .accessibilityIdentifier("builtinReview.window")
    }

    /// Unified single-tier header bar that houses sub-route navigation, optional Lingrove/Anki
    /// target switching, and review utility actions without double-header stacking.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                heading
                Spacer(minLength: 12)
                actions(inlineTarget: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    heading
                    Spacer(minLength: 8)
                    if let targetNavigation {
                        NotebookReviewTargetSwitch(navigation: targetNavigation, session: session)
                    }
                }
                actions(inlineTarget: false).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .background(.bar)
    }

    private var heading: some View {
        HStack(spacing: 12) {
            if isDetail || session.route == .adding {
                Button { session.route = isDetail ? (session.browsing.detailOrigin ?? .content) : .content } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text(BuiltInReviewCopy.text(isDetail && session.browsing.detailOrigin == .adding
                            ? "action.addContent" : "nav.content"))
                            .font(.subheadline.weight(.medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help(BuiltInReviewCopy.text("nav.content"))
                .accessibilityIdentifier("builtinReview.back")
                .disabled(session.isBusy)
            }
            if session.route == .overview || session.route == .content {
                Picker(BuiltInReviewCopy.text("nav.lingrove"), selection: $session.route) {
                    Text(BuiltInReviewCopy.text("nav.today")).tag(BuiltInReviewRoute.overview)
                    Text(BuiltInReviewCopy.text("nav.content")).tag(BuiltInReviewRoute.content)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .labelsHidden()
                .accessibilityIdentifier("builtinReview.navigation")
            } else {
                Text(pageTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
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

    private func actions(inlineTarget: Bool) -> some View {
        HStack(spacing: 8) {
            if session.isBusy { ProgressView().controlSize(.small) }
            Group {
                if session.route == .practice, session.practice?.phase.context != nil {
                    Button(BuiltInReviewCopy.text("action.endPractice")) { session.endPractice() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("builtinReview.finish")
                }
                if let undo = session.latestUndo {
                    Button { session.undo(undo) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help(BuiltInReviewCopy.text("action.undo"))
                        .accessibilityLabel(BuiltInReviewCopy.text("action.undo"))
                        .accessibilityIdentifier("builtinReview.session.undo")
                }
                Menu {
                    ForEach(session.content?.noteTypes ?? []) { type in
                        Button {
                            session.editNoteType(type)
                        } label: {
                            HStack {
                                Text(BuiltInReviewCopy.noteTypeName(type))
                                if type.id == session.content?.defaultNoteType.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(String(localized: "Card templates", table: "Vocabulary"), systemImage: "rectangle.stack")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Card templates", table: "Vocabulary"))
                .accessibilityIdentifier("builtinReview.templates")

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
            .disabled(session.isBusy || session.content == nil)

            if inlineTarget, let targetNavigation {
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)
                NotebookReviewTargetSwitch(navigation: targetNavigation, session: session)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    @ViewBuilder private func destination(_ content: NotebookBuiltInReviewSnapshot, index: BuiltInReviewContentState) -> some View {
        switch session.route {
        case .overview:
            BuiltInReviewOverviewView(session: session, content: content)
        case .content, .adding, .sense:
            let detail: VocabularySelection? = if case let .sense(selection) = session.route { selection } else { nil }
            VStack(spacing: 0) {
                if detail == nil, session.addedCount > 0 {
                    addedFeedbackBanner(content)
                }
                if session.route == .adding {
                    BuiltInReviewContentView(content: content, index: index,
                        selections: index.selections(adding: true, filter: session.browsing.filter, search: session.browsing.addingSearch),
                        browsing: $session.browsing, adding: true, onAdd: session.showAdding,
                        onEnroll: session.requestBatch, onSelect: session.showDetail)
                } else if let detail, session.browsing.detailOrigin != .content {
                    BuiltInReviewSenseView(session: session, selection: detail, content: content)
                } else {
                    // The list stays mounted when selecting a row or clearing it via search.
                    contentSplitOrSingle(content: content, index: index, explicitSelection: detail)
                }
            }
            .disabled(session.isBusy)
        case .practice:
            BuiltInReviewPracticeView(session: session, content: content)
        }
    }

    private func addedFeedbackBanner(_ content: NotebookBuiltInReviewSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(BuiltInReviewCopy.text("message.added"))
                .font(.subheadline.weight(.medium))
            Text(session.addedCount.formatted())
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(Color.green.opacity(0.15)))
                .foregroundStyle(.green)
            Spacer()
            Button(BuiltInReviewCopy.text("action.start")) { session.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(content.queue.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.06))
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    /// Presents a three-column-harmonious master-detail split when the workspace window is wide,
    /// while falling back to single-column navigation in narrow windows.
    @ViewBuilder
    private func contentSplitOrSingle(
        content: NotebookBuiltInReviewSnapshot, index: BuiltInReviewContentState, explicitSelection: VocabularySelection?
    ) -> some View {
        let selections = session.contentSelections
        let activeSelection = explicitSelection ?? selections.first

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                BuiltInReviewContentView(
                    content: content,
                    index: index,
                    selections: selections,
                    browsing: $session.browsing,
                    adding: false,
                    selectedSenseID: activeSelection?.senseID,
                    onAdd: session.showAdding,
                    onEnroll: session.requestBatch,
                    onSelect: session.showDetail
                )
                .frame(width: 330)

                Divider().opacity(0.6)

                Group {
                    if let activeSelection {
                        BuiltInReviewSenseView(session: session, selection: activeSelection, content: content)
                            .id(activeSelection.senseID)
                    } else {
                        ContentUnavailableView(
                            BuiltInReviewCopy.text("state.noMatches"),
                            systemImage: "rectangle.stack"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 780)

            Group {
                if let explicitSelection {
                    BuiltInReviewSenseView(session: session, selection: explicitSelection, content: content)
                } else {
                    BuiltInReviewContentView(
                        content: content,
                        index: index,
                        selections: selections,
                        browsing: $session.browsing,
                        adding: false,
                        onAdd: session.showAdding,
                        onEnroll: session.requestBatch,
                        onSelect: session.showDetail
                    )
                }
            }
        }
    }
}
