// Empty-state/queue structure adapted from Nibomo ReviewView and ReviewQueuePreviewScreen (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// Nibomo’s review empty state replaces the old bespoke metric dashboard. This destination
/// reports the shared queue and offers only real local actions; opening it writes nothing.
struct BuiltInReviewOverviewView: View {
    @ObservedObject var session: BuiltInReviewSession
    let content: NotebookBuiltInReviewSnapshot

    var body: some View {
        ContentUnavailableView {
            Label(content.queue.isEmpty ? String(localized: "Nothing Due", table: "ReviewCards")
                : String(localized: "Review", table: "ReviewCards"),
                systemImage: content.queue.isEmpty ? "checkmark.circle" : "rectangle.on.rectangle")
        } description: {
            Text(BuiltInReviewCopy.text(content.review.groups.isEmpty ? "state.noSelection" : "session.scheduled"))
        } actions: {
            VStack(spacing: 12) {
                if !content.queue.isEmpty {
                    Button { session.start() } label: {
                        Label(BuiltInReviewCopy.text("action.start"), systemImage: "play.fill")
                    }.lingroveNativeProminentActionButtonStyle().accessibilityIdentifier("builtinReview.start")
                }
                Text(BuiltInReviewCopy.text("description.selection")).font(.caption).foregroundStyle(.secondary)
                LabeledContent(BuiltInReviewCopy.text("count.activeSenses"), value: content.statistics.activeSenses.formatted())
                LabeledContent(BuiltInReviewCopy.text("count.exercises"), value: content.statistics.exercises.formatted())
            }.frame(maxWidth: 390)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("builtinReview.overview.content")
    }
}

/// The selected-sense sheet adopts Nibomo’s List/Section material browser. Participation and
/// saved corpus stay distinct: choosing either row opens details and does not enroll a sense.
struct BuiltInReviewSenseChooser: View {
    let content: NotebookBuiltInReviewSnapshot
    let onSelect: (VocabularySelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section(BuiltInReviewCopy.text("nav.selected")) {
                    ForEach(content.review.groups.values.sorted { $0.selection.senseID.uuidString < $1.selection.senseID.uuidString },
                            id: \.selection.senseID) { group in
                        let source = BuiltInReviewSource.value(group.selection, in: content.scope)
                        if matches(source?.entry.expression ?? "", source?.sense.meaning ?? "") {
                            Button { onSelect(group.selection) } label: {
                                row(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource"),
                                    detail: BuiltInReviewCopy.status(group.status))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Section(BuiltInReviewCopy.text("action.choose")) {
                    Text(BuiltInReviewCopy.text("description.choose")).foregroundStyle(.secondary)
                    ForEach(content.scope.document.collectedEntries) { entry in
                        ForEach(entry.senses.filter { matches(entry.expression, $0.meaning) }) { sense in
                            Button { onSelect(.init(entryID: entry.id, senseID: sense.id)) } label: {
                                row(entry.expression, detail: sense.meaning)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.listStyle(.inset).searchable(text: $search, prompt: BuiltInReviewCopy.text("field.search"))
                .navigationTitle(BuiltInReviewCopy.text("nav.selected"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(BuiltInReviewCopy.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
        }.frame(width: 620, height: 560).tint(.orange).preferredColorScheme(.dark)
    }

    private func row(_ title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
            }.background(.thinMaterial).navigationTitle(String(localized: "Review", table: "ReviewCards"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Close", table: "ReviewCards")) { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
        }.frame(width: 720, height: 580).preferredColorScheme(.dark).tint(.orange)
    }
}
