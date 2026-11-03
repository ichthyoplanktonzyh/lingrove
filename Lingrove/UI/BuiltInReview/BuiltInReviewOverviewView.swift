// Empty-state/queue structure adapted from Nibomo ReviewView and ReviewQueuePreviewScreen (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// Today is a projection of the frozen queue, never a command to begin practice. Each empty
/// state supplies one real next action; saved corpus, participation and scheduling stay distinct.
struct BuiltInReviewOverviewView: View {
    @ObservedObject var session: BuiltInReviewSession
    let content: NotebookBuiltInReviewSnapshot

    private var state: BuiltInReviewOverviewState { .init(content: content) }

    var body: some View {
        ScrollView {
            LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 24) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: state.symbol).font(.system(size: 32)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(BuiltInReviewCopy.text(state.titleKey)).font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        if let date = state.nextDue {
                            LabeledContent(BuiltInReviewCopy.text("session.nextDue"),
                                value: date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            switch state {
                            case .due: session.start()
                            case .noCorpus: session.onBrowseCorpus?()
                            default: session.route = .content
                            }
                        } label: {
                            Label(BuiltInReviewCopy.text(state.actionKey), systemImage: state == .due ? "play.fill" : "arrow.right")
                        }
                        .lingroveNativeProminentActionButtonStyle().controlSize(.large)
                        .accessibilityIdentifier(state == .due ? "builtinReview.start" : "builtinReview.overview.primary")
                    }
                    HStack(alignment: .top, spacing: 20) {
                        metric("count.ready", value: content.queue.count)
                        metric("count.activeSenses", value: content.statistics.activeSenses)
                        metric("count.exercises", value: content.statistics.exercises)
                    }
                    .padding(20)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }.padding(.vertical, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("builtinReview.overview.content")
    }

    private func metric(_ key: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title2.weight(.semibold)).monospacedDigit()
            Text(BuiltInReviewCopy.text(key)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One content browser separates participation from available corpus. A sense occurs once in
/// the current filter, including paused/withdrawn material whose recipe and history are retained.
struct BuiltInReviewContentView: View {
    let content: NotebookBuiltInReviewSnapshot
    let onSelect: (VocabularySelection) -> Void
    @State private var search = ""
    @State private var available = false

    private var selections: [VocabularySelection] {
        let values: [VocabularySelection]
        if available {
            values = content.scope.document.collectedEntries.flatMap { entry in
                entry.senses.filter { content.review.groups[$0.id]?.cards.isEmpty != false }
                    .map { .init(entryID: entry.id, senseID: $0.id) }
            }
        } else { values = content.review.groups.values.map(\.selection) }
        return values.filter { selection in
            let source = BuiltInReviewSource.value(selection, in: content.scope)
            return search.isEmpty || source?.entry.expression.localizedCaseInsensitiveContains(search) == true
                || source?.sense.meaning.localizedCaseInsensitiveContains(search) == true
        }.sorted { lhs, rhs in
            let left = BuiltInReviewSource.value(lhs, in: content.scope)?.entry.expression ?? ""
            let right = BuiltInReviewSource.value(rhs, in: content.scope)?.entry.expression ?? ""
            return left == right ? lhs.senseID.uuidString < rhs.senseID.uuidString
                : left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(BuiltInReviewCopy.text("nav.content"), selection: $available) {
                Text(BuiltInReviewCopy.text("nav.enrolled")).tag(false)
                Text(BuiltInReviewCopy.text("action.addContent")).tag(true)
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.vertical, 16)
                .accessibilityIdentifier("builtinReview.content.filter")
            List(selections, id: \.senseID) { selection in
                let source = BuiltInReviewSource.value(selection, in: content.scope)
                let group = content.review.groups[selection.senseID]
                Button { onSelect(selection) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource"))
                            Text(source?.sense.meaning ?? BuiltInReviewCopy.text("material.retained"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(group.map { BuiltInReviewCopy.text(
                                $0.hasUnavailableMaterial ? "material.unavailable" : "status." + $0.status.rawValue) }
                                ?? BuiltInReviewCopy.text("status.notSelected")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }.padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .listStyle(.inset).searchable(text: $search, prompt: BuiltInReviewCopy.text("field.search"))
            .overlay {
                if selections.isEmpty {
                    ContentUnavailableView(BuiltInReviewCopy.text(available ? "state.noCorpus" : "state.noSelection"), systemImage: "tray")
                }
            }
        }
        .onAppear { if content.review.groups.isEmpty { available = true } }
        .accessibilityIdentifier("builtinReview.content")
    }
}

/// Kept as a compact host for clients that request a chooser sheet; it delegates the same
/// content browser rather than maintaining a second enrolled/all-source list.
struct BuiltInReviewSenseChooser: View {
    let content: NotebookBuiltInReviewSnapshot
    let onSelect: (VocabularySelection) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            BuiltInReviewContentView(content: content, onSelect: onSelect)
                .navigationTitle(BuiltInReviewCopy.text("nav.content"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(BuiltInReviewCopy.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("builtinReview.senseChooser.cancel")
                    }
                }
        }.frame(minWidth: 540, idealWidth: 620, minHeight: 460, idealHeight: 560)
            .accessibilityIdentifier("builtinReview.senseChooser")
    }
}

/// The preview uses Nibomo’s extracted rows and active/later separator. The frozen snapshot
/// already bounds its contents, so no second paginated store or background network loader exists.
struct BuiltInReviewQueuePreviewView: View {
    let content: NotebookBuiltInReviewSnapshot
    let currentCardID: String?
    @Environment(\.dismiss) private var dismiss

    private var later: [Card] {
        let ready = Set(content.queue.map(\.cardId))
        return content.review.groups.values.filter { $0.status == .active && !$0.hasUnavailableMaterial }
            .flatMap(\.cards).filter { !ready.contains($0.cardId) }
            .sorted { ($0.dueAt ?? "") < ($1.dueAt ?? "") }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LingroveReadableContentLayout(maxWidth: lingroveReadableContentMaxWidth, horizontalPadding: 20) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(content.queue) { card in
                            LingroveReviewQueuePreviewCardRow(card: card, isCurrent: card.cardId == currentCardID)
                        }
                        if !later.isEmpty {
                            LingroveReviewQueueSectionSeparator()
                            ForEach(later) { card in LingroveReviewQueuePreviewCardRow(card: card, isCurrent: false) }
                        }
                        if content.queue.isEmpty && later.isEmpty {
                            ContentUnavailableView(String(localized: "Nothing Due", table: "ReviewCards"), systemImage: "tray")
                        }
                    }.padding(.vertical, 20)
                }
            }
                .background(Color(nsColor: .windowBackgroundColor))
                .navigationTitle(BuiltInReviewCopy.text("queue.title"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Close", table: "ReviewCards")) { dismiss() }.keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("builtinReview.queuePreview.close")
                    }
                }
        }
        .frame(minWidth: 540, idealWidth: 720, minHeight: 460, idealHeight: 580)
        .accessibilityIdentifier("builtinReview.queuePreview")
    }
}
