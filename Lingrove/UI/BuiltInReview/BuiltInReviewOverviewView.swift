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
                            case .noSelection: session.showAdding()
                            case .paused: session.showContent(filter: .paused)
                            case .withdrawn: session.showContent(filter: .withdrawn)
                            case .unavailable: session.showContent(filter: .attention)
                            case .scheduled: session.showContent()
                            }
                        } label: {
                            Label(BuiltInReviewCopy.text(state.actionKey), systemImage: state == .due ? "play.fill" : "arrow.right")
                        }
                        .lingroveNativeProminentActionButtonStyle().controlSize(.large)
                        .accessibilityIdentifier(state == .due ? "builtinReview.start" : "builtinReview.overview.primary")
                    }
                    if state == .due {
                        LabeledContent(BuiltInReviewCopy.text("count.ready"), value: content.queue.count.formatted())
                            .font(.title3).monospacedDigit()
                    }
                    if state != .noCorpus && state != .noSelection {
                        Button(BuiltInReviewCopy.text("action.addContent"), systemImage: "plus") { session.showAdding() }
                    }
                    if state != .unavailable, content.review.groups.values.contains(where: \.hasUnavailableMaterial) {
                        Button(BuiltInReviewCopy.text("action.fixMaterial"), systemImage: "exclamationmark.triangle") {
                            session.showContent(filter: .attention)
                        }
                    }
                }.padding(.vertical, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("builtinReview.overview.content")
    }

}

/// This browser borrows session-owned search and filters. Adding is an explicit destination;
/// a detail round trip does not recreate local state or silently switch the visible list.
struct BuiltInReviewContentView: View {
    let content: NotebookBuiltInReviewSnapshot
    @Binding var browsing: BuiltInReviewBrowsing
    var adding = false
    var onAdd: (() -> Void)?
    var onEnroll: (([VocabularySelection]) -> Void)?
    let onSelect: (VocabularySelection) -> Void

    private var search: Binding<String> { adding ? $browsing.addingSearch : $browsing.search }
    private var selections: [VocabularySelection] {
        BuiltInReviewContentState.selections(in: content, adding: adding, filter: browsing.filter, search: search.wrappedValue)
    }
    private var selected: [VocabularySelection] {
        BuiltInReviewContentState.selections(in: content, adding: true, filter: browsing.filter, search: "")
            .filter { browsing.selectedSenseIDs.contains($0.senseID) }
    }
    private var emptyTitle: String {
        if !adding { return BuiltInReviewCopy.text("state.noMatches") }
        return BuiltInReviewCopy.text(content.scope.document.collectedEntries.isEmpty ? "state.noCorpus" : "state.allAdded")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !adding {
                    Picker(BuiltInReviewCopy.text("nav.content"), selection: $browsing.filter) {
                        ForEach(BuiltInReviewContentFilter.allCases, id: \.self) { filter in
                            Text(BuiltInReviewCopy.text(filter.titleKey)).tag(filter)
                        }
                    }.accessibilityIdentifier("builtinReview.content.filter")
                    Spacer()
                    Button(BuiltInReviewCopy.text("action.addContent"), systemImage: "plus") { onAdd?() }
                        .accessibilityIdentifier("builtinReview.content.add")
                } else if let onEnroll {
                    Text(BuiltInReviewCopy.text("nav.selected"))
                    Text(selected.count.formatted()).monospacedDigit()
                    Spacer()
                    Button(BuiltInReviewCopy.text("action.enroll")) { onEnroll(selected) }
                        .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
                        .accessibilityIdentifier("builtinReview.content.enrollSelected")
                }
            }.padding(.horizontal, 24).padding(.vertical, 12)
            List(selections, id: \.senseID) { selection in
                HStack(spacing: 12) {
                    if adding, onEnroll != nil {
                        Toggle(BuiltInReviewCopy.text("action.enroll"), isOn: Binding(
                            get: { browsing.selectedSenseIDs.contains(selection.senseID) },
                            set: { selected in
                                if selected {
                                    browsing.selectedSenseIDs.insert(selection.senseID)
                                } else { browsing.selectedSenseIDs.remove(selection.senseID) }
                            }))
                            .toggleStyle(.checkbox).labelsHidden()
                            .accessibilityLabel(BuiltInReviewSource.value(selection, in: content.scope)?.entry.expression ?? "")
                    }
                    Button { onSelect(selection) } label: { row(selection) }.buttonStyle(.plain)
                }
            }.listStyle(.inset).searchable(text: search, prompt: BuiltInReviewCopy.text("field.search"))
                .overlay {
                    if selections.isEmpty {
                        if !search.wrappedValue.isEmpty {
                            ContentUnavailableView.search(text: search.wrappedValue)
                        } else { ContentUnavailableView(emptyTitle, systemImage: "tray") }
                    }
                }
        }.accessibilityIdentifier("builtinReview.content")
    }

    private func row(_ selection: VocabularySelection) -> some View {
        let source = BuiltInReviewSource.value(selection, in: content.scope)
        let group = content.review.groups[selection.senseID]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource"))
                Text(source?.sense.meaning ?? BuiltInReviewCopy.text("material.retained"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let group {
                    Text(BuiltInReviewCopy.status(group.status)).font(.caption).foregroundStyle(.secondary)
                    if group.hasUnavailableMaterial {
                        Label(BuiltInReviewCopy.text("material.unavailable"), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
}

/// A standalone chooser owns only temporary browsing state; it shares the same list projection.
struct BuiltInReviewSenseChooser: View {
    let content: NotebookBuiltInReviewSnapshot
    let onSelect: (VocabularySelection) -> Void
    @State private var browsing = BuiltInReviewBrowsing()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            BuiltInReviewContentView(content: content, browsing: $browsing, adding: true, onSelect: onSelect)
                .navigationTitle(BuiltInReviewCopy.text("action.addContent"))
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
