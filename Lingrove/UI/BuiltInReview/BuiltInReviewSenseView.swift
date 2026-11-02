import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// Sense details separate source ownership from exercise ownership. A single sense can expose
/// several Cards with independent schedules; pause/withdraw affects participation and keeps
/// all authored faces and history. Missing sources remain reachable here through enrollment.
struct BuiltInReviewSenseView: View {
    @ObservedObject var session: BuiltInReviewSession
    let selection: VocabularySelection
    let content: NotebookBuiltInReviewSnapshot

    private var source: (entry: VocabularyEntry, sense: VocabularySense)? {
        BuiltInReviewSource.value(selection, in: content.scope)
    }
    private var group: LingroveNotebookReviewGroup? {
        content.review.groups[source?.sense.id ?? selection.senseID]
    }
    private var currentSelection: VocabularySelection {
        source.map { .init(entryID: $0.entry.id, senseID: $0.sense.id) } ?? selection
    }
    private var isCollected: Bool {
        content.scope.document.collectedEntries.contains { entry in
            entry.id == currentSelection.entryID && entry.senses.contains { $0.id == currentSelection.senseID }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource"))
                        .font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                    if let source { Text(source.sense.meaning).font(.title3).textSelection(.enabled) }
                    Text(group.map { BuiltInReviewCopy.status($0.status) } ?? BuiltInReviewCopy.text("status.notSelected"))
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
                if let group, !group.cards.isEmpty {
                    participation(group)
                    LabeledContent(BuiltInReviewCopy.text("count.exercises"), value: group.cards.count.formatted())
                    ForEach(group.cards) { card in
                        if let context = session.context(card: card, group: group, content: content) { exercise(context) }
                    }
                    if source != nil {
                        Button(BuiltInReviewCopy.text("action.addExercise"), systemImage: "plus.rectangle.on.rectangle") {
                            session.prepare(selection: currentSelection, additional: true, basedOn: content)
                        }.accessibilityIdentifier("builtinReview.addExercise")
                    }
                } else if source != nil, isCollected {
                    Text(BuiltInReviewCopy.text("description.enroll")).foregroundStyle(.secondary)
                    if let material = try? LingroveNotebookCardMaterial.draft(snapshot: content.scope, selection: currentSelection) {
                        GroupBox(BuiltInReviewCopy.text("material.default")) {
                            VStack(alignment: .leading, spacing: 14) {
                                BuiltInReviewFace(text: material.generatedContent.frontText, images: [])
                                Divider()
                                BuiltInReviewFace(text: material.generatedContent.backText, images: [])
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    HStack {
                        Button(BuiltInReviewCopy.text("action.enroll"), systemImage: "checkmark.circle") {
                            session.enrollDefault(selection: currentSelection, basedOn: content)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("builtinReview.enroll")
                        Button(BuiltInReviewCopy.text("action.prepare")) {
                            session.prepare(selection: currentSelection, basedOn: content)
                        }.accessibilityIdentifier("builtinReview.prepare")
                    }
                } else {
                    Text(BuiltInReviewCopy.text(source == nil ? "error.source" : "state.saveFirst"))
                        .foregroundStyle(.secondary)
                }
                Text(BuiltInReviewCopy.text("description.retention")).font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 900, alignment: .leading).disabled(session.isBusy)
        }.accessibilityIdentifier("builtinReview.sense.detail")
    }

    private func participation(_ group: LingroveNotebookReviewGroup) -> some View {
        HStack(spacing: 10) {
            if group.status == .active {
                Button(BuiltInReviewCopy.text("action.start"), systemImage: "play.fill") {
                    session.start(selection: group.selection)
                }.buttonStyle(.borderedProminent)
                    .disabled(!content.queue.contains { card in group.cards.contains { $0.cardId == card.cardId } })
                Button(BuiltInReviewCopy.text("action.pause")) { changeStatus(.paused, group) }
                    .accessibilityIdentifier("builtinReview.pause")
            } else {
                Button(BuiltInReviewCopy.text(group.status == .withdrawn ? "action.rejoin" : "action.resume"),
                       systemImage: "play.circle") { changeStatus(.active, group) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("builtinReview.resume")
            }
            if group.status != .withdrawn {
                Button(BuiltInReviewCopy.text("action.withdraw"), role: .destructive) { changeStatus(.withdrawn, group) }
                    .accessibilityIdentifier("builtinReview.withdraw")
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func changeStatus(_ status: LingroveNotebookReviewStatus, _ group: LingroveNotebookReviewGroup) {
        session.setStatus(status, selection: group.selection, basedOn: content)
    }

    private func exercise(_ context: BuiltInReviewCardContext) -> some View {
        let material = LingroveNotebookCardMaterial.resolve(source: context.link.source, snapshot: content.scope)
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(BuiltInReviewText.attributed(context.card.frontText))
                    .font(.headline).lineLimit(4).textSelection(.enabled)
                HStack {
                    Text(BuiltInReviewCopy.text(context.card.reps == 0 ? "state.new" : "state.practiced"))
                    Spacer()
                    LabeledContent(BuiltInReviewCopy.text("count.cardReviews"), value: context.card.reps.formatted())
                }.font(.caption).foregroundStyle(.secondary)
                if let due = context.card.dueAt.flatMap({ parseIsoTimestamp(value: $0) }) {
                    LabeledContent(BuiltInReviewCopy.text("field.due")) {
                        Text(due, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if material == nil {
                    Label(BuiltInReviewCopy.text(context.link.allowsUnavailableMaterial ? "material.retained" : "material.unavailable"),
                          systemImage: context.link.allowsUnavailableMaterial ? "archivebox" : "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                    if !context.link.allowsUnavailableMaterial {
                        Button(BuiltInReviewCopy.text("action.retain")) { session.retain(context) }
                            .accessibilityIdentifier("builtinReview.retain")
                    }
                }
                HStack {
                    Button(BuiltInReviewCopy.text("action.edit")) {
                        session.edit(card: context.card, link: context.link, selection: context.group.selection, basedOn: content)
                    }.disabled(source == nil && !context.link.allowsUnavailableMaterial)
                        .accessibilityIdentifier("builtinReview.edit." + context.card.cardId)
                    if let undo = session.undoAction(cardID: context.card.cardId, basedOn: content) {
                        Button(BuiltInReviewCopy.text("action.undo")) { session.undo(undo) }
                            .accessibilityIdentifier("builtinReview.undo." + context.card.cardId)
                    }
                    Spacer()
                    if source != nil, session.onOpenSource != nil {
                        Button(BuiltInReviewCopy.text("action.source"), systemImage: "arrow.up.forward.square") {
                            session.openSource(context)
                        }
                    }
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
