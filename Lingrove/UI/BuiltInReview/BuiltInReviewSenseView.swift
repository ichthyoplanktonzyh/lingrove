// Material-list structure adapted from Nibomo LingroveNotebookPreparationScreen.swift (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// The native grouped form displays one sense and its exercises. The app-owned session owns
/// commands and frozen snapshots; this view only projects participation and material, keeping
/// enrollment, source recovery and practice as separately named user actions.
struct BuiltInReviewSenseView: View {
    @ObservedObject var session: BuiltInReviewSession
    let selection: VocabularySelection
    let content: NotebookBuiltInReviewSnapshot

    private var source: (entry: VocabularyEntry, sense: VocabularySense)? {
        BuiltInReviewSource.value(selection, in: content.scope)
    }
    private var group: LingroveNotebookReviewGroup? { content.review.groups[source?.sense.id ?? selection.senseID] }
    private var currentSelection: VocabularySelection {
        source.map { .init(entryID: $0.entry.id, senseID: $0.sense.id) } ?? selection
    }
    private var isCollected: Bool {
        content.scope.document.collectedEntries.contains { entry in
            entry.id == currentSelection.entryID && entry.senses.contains { $0.id == currentSelection.senseID }
        }
    }

    var body: some View {
        LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 0) {
            Form {
                Section {
                    Text(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource"))
                        .font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let source { Text(source.sense.meaning).textSelection(.enabled) }
                    Text(group.map { BuiltInReviewCopy.status($0.status) } ?? BuiltInReviewCopy.text("status.notSelected"))
                        .foregroundStyle(.secondary)
                }
                if session.addedCount > 0 {
                    Section {
                        Label(BuiltInReviewCopy.text("message.added"), systemImage: "checkmark.circle")
                        Button(BuiltInReviewCopy.text("action.addContent")) { session.showAdding() }
                    }
                }
                if let group, !group.cards.isEmpty {
                    Section(BuiltInReviewCopy.text("nav.lingrove")) {
                        participation(group)
                    }
                    Section(BuiltInReviewCopy.text("count.exercises")) {
                        ForEach(group.cards) { card in
                            if let context = session.context(card: card, group: group, content: content) { exercise(context) }
                        }
                        if source != nil {
                            Button(BuiltInReviewCopy.text("action.addExercise"), systemImage: "plus.rectangle.on.rectangle") {
                                session.prepare(selection: currentSelection, additional: true, basedOn: content)
                            }.accessibilityIdentifier("builtinReview.addExercise")
                        }
                    }
                } else if source != nil, isCollected {
                    Section(BuiltInReviewCopy.text("material.default")) {
                        if let material = try? LingroveNotebookCardMaterial.draft(snapshot: content.scope, selection: currentSelection) {
                            Text(BuiltInReviewCopy.text("field.prompt")).font(.caption).foregroundStyle(.secondary)
                            BuiltInReviewFace(text: material.generatedContent.frontText, images: [])
                            Divider()
                            Text(BuiltInReviewCopy.text("field.answer")).font(.caption).foregroundStyle(.secondary)
                            BuiltInReviewFace(text: material.generatedContent.backText, images: [])
                        }
                    }
                    Section {
                        Button(BuiltInReviewCopy.text("action.enroll"), systemImage: "checkmark.circle") {
                            session.enrollDefault(selection: currentSelection, basedOn: content)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("builtinReview.enroll")
                        Button(BuiltInReviewCopy.text("action.prepare")) {
                            session.prepare(selection: currentSelection, basedOn: content)
                        }.accessibilityIdentifier("builtinReview.prepare")
                    }
                } else {
                    Text(BuiltInReviewCopy.text(source == nil ? "error.source" : "state.saveFirst")).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).padding(.top, 8).disabled(session.isBusy)
        }.accessibilityIdentifier("builtinReview.sense.detail")
    }

    @ViewBuilder private func participation(_ group: LingroveNotebookReviewGroup) -> some View {
        if group.status == .active {
            if content.queue.contains(where: { card in group.cards.contains { $0.cardId == card.cardId } }) {
                Button(BuiltInReviewCopy.text("action.start"), systemImage: "play.fill") { session.start(selection: group.selection) }
                    .buttonStyle(.borderedProminent)
            } else {
                Text(BuiltInReviewCopy.text(group.hasUnavailableMaterial ? "material.unavailable" : "today.scheduled"))
                    .foregroundStyle(.secondary)
                if !group.hasUnavailableMaterial,
                   let date = group.cards.compactMap({ $0.dueAt.flatMap { parseIsoTimestamp(value: $0) } }).min() {
                    LabeledContent(BuiltInReviewCopy.text("session.nextDue"),
                        value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Button(BuiltInReviewCopy.text("action.pause")) { changeStatus(.paused, group) }
                .accessibilityIdentifier("builtinReview.pause")
        } else {
            Button(BuiltInReviewCopy.text(group.status == .withdrawn ? "action.rejoin" : "action.resume"), systemImage: "play.circle") {
                changeStatus(.active, group)
            }.accessibilityIdentifier("builtinReview.resume")
        }
        Text(BuiltInReviewCopy.text("status.retention")).font(.caption).foregroundStyle(.secondary)
        if group.status != .withdrawn {
            Button(BuiltInReviewCopy.text("action.withdraw"), role: .destructive) { changeStatus(.withdrawn, group) }
                .accessibilityIdentifier("builtinReview.withdraw")
        }
    }

    private func changeStatus(_ status: LingroveNotebookReviewStatus, _ group: LingroveNotebookReviewGroup) {
        session.setStatus(status, selection: group.selection, basedOn: content)
    }

    private func exercise(_ context: BuiltInReviewCardContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LingroveReviewQueuePreviewCardRow(card: context.card, isCurrent: false)
            if context.group.hasUnavailableMaterial ||
                LingroveNotebookCardMaterial.resolve(source: context.link.source, snapshot: content.scope) == nil {
                Label(BuiltInReviewCopy.text(context.link.allowsUnavailableMaterial ? "material.retained" : "material.unavailable"),
                    systemImage: context.link.allowsUnavailableMaterial ? "archivebox" : "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
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
                    Button(BuiltInReviewCopy.text("action.source"), systemImage: "arrow.up.forward.square") { session.openSource(context) }
                }
            }
        }.padding(.vertical, 8)
    }
}
