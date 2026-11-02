import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// A presentation-only native root. The app graph supplies its single session; selecting a
/// row changes navigation, while explicit buttons pass the displayed saved value to commands.
struct BuiltInReviewWindowView: View {
    @ObservedObject var session: BuiltInReviewSession
    @State private var choosingSense = false

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
                Divider()
            }
            if let content = session.content {
                HSplitView {
                    sidebar(content).frame(minWidth: 205, idealWidth: 235, maxWidth: 300)
                    destination(content).frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView {
                    Label(BuiltInReviewCopy.text(session.isRefreshing ? "state.loading" : "state.unavailable"),
                          systemImage: session.isRefreshing ? "hourglass" : "exclamationmark.triangle")
                } description: {
                    Text(BuiltInReviewCopy.text("description.offline"))
                } actions: {
                    if session.isRefreshing { ProgressView() } else {
                        Button(BuiltInReviewCopy.text("action.refresh")) { session.reload() }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $choosingSense) {
            if let content = session.content {
                BuiltInReviewSenseChooser(content: content) { selection in
                    choosingSense = false
                    session.route = .sense(selection)
                }
            }
        }
        .sheet(item: $session.draft) { draft in BuiltInReviewPreparationView(session: session, draft: draft) }
        .accessibilityIdentifier("builtinReview.window")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(BuiltInReviewCopy.text("title")).font(.headline)
                Text(BuiltInReviewCopy.text("description.selection")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.isBusy { ProgressView().controlSize(.small).accessibilityLabel(BuiltInReviewCopy.text("state.loading")) }
            Button(BuiltInReviewCopy.text("action.choose"), systemImage: "plus") { choosingSense = true }
                .disabled(session.isBusy || session.content == nil || session.route == .practice)
                .accessibilityIdentifier("builtinReview.choose")
            Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help(BuiltInReviewCopy.text("action.refresh")).disabled(session.isBusy)
                .accessibilityLabel(BuiltInReviewCopy.text("action.refresh"))
        }.padding(16)
    }

    private func sidebar(_ content: NotebookBuiltInReviewSnapshot) -> some View {
        List {
            Button { session.endPractice() } label: {
                Label(BuiltInReviewCopy.text("nav.overview"), systemImage: "chart.bar")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
            }.buttonStyle(.plain).accessibilityIdentifier("builtinReview.overview")
            Section(BuiltInReviewCopy.text("nav.selected")) {
                ForEach(groups(content), id: \.selection.senseID) { group in
                    Button {
                        session.endPractice()
                        session.route = .sense(group.selection)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sourceTitle(group, content: content)).font(.body.weight(.medium)).lineLimit(2)
                            if let source = BuiltInReviewSource.value(group.selection, in: content.scope) {
                                Text(source.sense.meaning).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(BuiltInReviewCopy.status(group.status)).font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("builtinReview.sense." + group.selection.senseID.uuidString)
                }
            }
        }.listStyle(.sidebar).disabled(session.isBusy)
    }

    @ViewBuilder
    private func destination(_ content: NotebookBuiltInReviewSnapshot) -> some View {
        switch session.route {
        case .overview: BuiltInReviewOverviewView(session: session, content: content)
        case let .sense(selection): BuiltInReviewSenseView(session: session, selection: selection, content: content)
        case .practice: BuiltInReviewPracticeView(session: session, content: content)
        }
    }

    private func groups(_ content: NotebookBuiltInReviewSnapshot) -> [LingroveNotebookReviewGroup] {
        content.review.groups.values.sorted { lhs, rhs in
            let left = sourceTitle(lhs, content: content)
            let right = sourceTitle(rhs, content: content)
            if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            return lhs.selection.senseID.uuidString < rhs.selection.senseID.uuidString
        }
    }

    private func sourceTitle(_ group: LingroveNotebookReviewGroup, content: NotebookBuiltInReviewSnapshot) -> String {
        BuiltInReviewSource.value(group.selection, in: content.scope)?.entry.expression
            ?? BuiltInReviewCopy.text("state.missingSource")
    }
}

/// The source projection is used only for labels and navigation. Historical review identity
/// stays on enrollments/links, so a moved example cannot retarget a practice record.
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
