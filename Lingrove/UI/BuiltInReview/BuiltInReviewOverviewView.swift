// Empty-state/queue structure adapted from Nibomo ReviewView and ReviewQueuePreviewScreen (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The overview projects the session's immutable queue into one native landing page. It names
/// readiness separately from participation, so opening the page never looks like enrollment.
struct BuiltInReviewOverviewView: View {
    @ObservedObject var session: BuiltInReviewSession
    let content: NotebookBuiltInReviewSnapshot

    var body: some View {
        ScrollView {
            LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 24) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: content.queue.isEmpty ? "checkmark.circle" : "rectangle.on.rectangle")
                            .font(.system(size: 32, weight: .regular)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(content.queue.isEmpty ? String(localized: "Nothing Due", table: "ReviewCards")
                            : BuiltInReviewCopy.text("action.start"))
                            .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text(BuiltInReviewCopy.text("description.overview")).foregroundStyle(.secondary)
                        Text(BuiltInReviewCopy.text(statusKey)).foregroundStyle(.secondary)
                        if !content.queue.isEmpty {
                            Button { session.start() } label: {
                                Label(BuiltInReviewCopy.text("action.start"), systemImage: "play.fill")
                            }
                            .lingroveNativeProminentActionButtonStyle()
                            .controlSize(.large)
                            .accessibilityIdentifier("builtinReview.start")
                        }
                    }
                    HStack(alignment: .top, spacing: 20) {
                        metric("count.ready", value: content.queue.count)
                        metric("count.activeSenses", value: content.statistics.activeSenses)
                        metric("count.exercises", value: content.statistics.exercises)
                    }
                    .padding(20)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    Text(BuiltInReviewCopy.text("description.selection"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("builtinReview.overview.content")
    }

    private var statusKey: String {
        if content.scope.document.collectedEntries.isEmpty { return "state.noCorpus" }
        return content.review.groups.isEmpty ? "state.noSelection" : "session.scheduled"
    }

    private func metric(_ key: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title2.weight(.semibold)).monospacedDigit()
            Text(BuiltInReviewCopy.text(key)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The selected-sense sheet adopts Nibomo’s List/Section material browser. Participation and
/// saved corpus stay distinct: choosing either row opens details and does not enroll a sense.
struct BuiltInReviewSenseChooser: View {
    let content: NotebookBuiltInReviewSnapshot
    let onSelect: (VocabularySelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var groups: [LingroveNotebookReviewGroup] {
        content.review.groups.values.filter {
            let source = BuiltInReviewSource.value($0.selection, in: content.scope)
            return matches(source?.entry.expression ?? "", source?.sense.meaning ?? "")
        }.sorted { $0.selection.senseID.uuidString < $1.selection.senseID.uuidString }
    }

    private var hasSavedMatches: Bool {
        content.scope.document.collectedEntries.contains { entry in
            entry.senses.contains { matches(entry.expression, $0.meaning) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(BuiltInReviewCopy.text("nav.selected")) {
                    ForEach(groups, id: \.selection.senseID) { group in
                        let source = BuiltInReviewSource.value(group.selection, in: content.scope)
                        Button { onSelect(group.selection) } label: {
                            row(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource"),
                                detail: source?.sense.meaning ?? BuiltInReviewCopy.text("state.missingSource"),
                                status: BuiltInReviewCopy.status(group.status))
                        }.buttonStyle(.plain)
                    }
                }
                Section(BuiltInReviewCopy.text("action.choose")) {
                    Text(BuiltInReviewCopy.text("description.choose")).foregroundStyle(.secondary)
                    ForEach(content.scope.document.collectedEntries) { entry in
                        ForEach(entry.senses.filter { matches(entry.expression, $0.meaning) }) { sense in
                            Button { onSelect(.init(entryID: entry.id, senseID: sense.id)) } label: {
                                row(entry.expression, detail: sense.meaning, status: nil)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
                .overlay {
                    if !search.isEmpty, groups.isEmpty, !hasSavedMatches { ContentUnavailableView.search(text: search) }
                }
                .listStyle(.inset).searchable(text: $search, prompt: BuiltInReviewCopy.text("field.search"))
                .navigationTitle(BuiltInReviewCopy.text("nav.selected"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(BuiltInReviewCopy.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("builtinReview.senseChooser.cancel")
                    }
                }
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 460, idealHeight: 560)
        .accessibilityIdentifier("builtinReview.senseChooser")
    }

    private func row(_ title: String, detail: String, status: String?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }

    private func matches(_ expression: String, _ meaning: String) -> Bool {
        search.isEmpty || expression.localizedCaseInsensitiveContains(search) || meaning.localizedCaseInsensitiveContains(search)
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
