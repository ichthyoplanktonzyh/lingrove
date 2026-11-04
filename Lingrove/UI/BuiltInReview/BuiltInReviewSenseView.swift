// Material-list structure adapted from Nibomo LingroveNotebookPreparationScreen.swift (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// Editorial detail pane for one sense and its review exercises. The app-owned session owns
/// commands and frozen snapshots; this view projects participation and material into cards,
/// keeping enrollment, source recovery and practice as separately named user actions.
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

    private var statusTint: Color {
        guard let status = group?.status else { return .secondary }
        switch status {
        case .active: return .green
        case .paused: return .orange
        case .withdrawn: return .secondary
        }
    }

    var body: some View {
        ScrollView {
            LingroveReadableContentLayout(maxWidth: lingroveReadableContentMaxWidth, horizontalPadding: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    if session.addedCount > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(BuiltInReviewCopy.text("message.added"))
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Button(BuiltInReviewCopy.text("action.addContent")) { session.showAdding() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        .padding(14)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5)
                        )
                    }

                    senseHeaderCard

                    if let group, !group.cards.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(BuiltInReviewCopy.text("count.exercises"), systemImage: "rectangle.on.rectangle")
                                    .font(.headline)
                                Text("\(group.cards.count)")
                                    .font(.caption.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                                Spacer()
                            }

                            ForEach(group.cards) { card in
                                if let context = session.context(card: card, group: group, content: content) {
                                    exercise(context)
                                }
                            }
                        }
                    } else if source == nil || !isCollected {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text(BuiltInReviewCopy.text(source == nil ? "error.source" : "state.saveFirst"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.vertical, 24)
            }
        }
        .disabled(session.isBusy)
        .accessibilityIdentifier("builtinReview.sense.detail")
    }

    private var senseHeaderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(source?.entry.expression ?? BuiltInReviewCopy.text("state.missingSource"))
                    .font(.title2.weight(.bold))
                    .textSelection(.enabled)

                Text(group.map { BuiltInReviewCopy.status($0.status) } ?? BuiltInReviewCopy.text("status.notSelected"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(statusTint.opacity(0.12)))

                Spacer(minLength: 0)

                if source != nil, let openSource = session.onOpenSource {
                    Button {
                        openSource(currentSelection)
                    } label: {
                        Label(BuiltInReviewCopy.text("action.source"), systemImage: "arrow.up.forward.square")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let source, !source.sense.meaning.isEmpty {
                Text(source.sense.meaning)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.9))
                    .textSelection(.enabled)
            }

            if let group, !group.cards.isEmpty {
                Divider().opacity(0.5)
                participation(group)
            } else if source != nil, isCollected {
                Divider().opacity(0.5)
                HStack {
                    Button(BuiltInReviewCopy.text("action.enroll"), systemImage: "checkmark.circle.fill") {
                        session.enrollDefault(selection: currentSelection, basedOn: content)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityIdentifier("builtinReview.enroll")
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
        )
    }

    @ViewBuilder private func participation(_ group: LingroveNotebookReviewGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if group.status == .active {
                    Button(BuiltInReviewCopy.text("action.pause"), systemImage: "pause.circle") {
                        changeStatus(.paused, group)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("builtinReview.pause")
                } else {
                    Button(BuiltInReviewCopy.text(group.status == .withdrawn ? "action.rejoin" : "action.resume"), systemImage: "play.circle.fill") {
                        changeStatus(.active, group)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("builtinReview.resume")
                }

                if group.status != .withdrawn {
                    Button(BuiltInReviewCopy.text("action.withdraw"), role: .destructive) {
                        changeStatus(.withdrawn, group)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("builtinReview.withdraw")
                }

                Spacer(minLength: 0)
            }

            Text(BuiltInReviewCopy.text("status.retention"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func changeStatus(_ status: LingroveNotebookReviewStatus, _ group: LingroveNotebookReviewGroup) {
        session.setStatus(status, selection: group.selection, basedOn: content)
    }

    private func exercise(_ context: BuiltInReviewCardContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LingroveReviewQueuePreviewCardRow(card: context.card, isCurrent: false)

            if let model = content.noteCards[context.card.cardId] {
                if model.noteType.templates.first(where: { $0.id == model.templateID })?.enabled == false {
                    Label(BuiltInReviewCopy.text("status.paused"), systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if (try? model.render(in: context.snapshot)) == nil {
                    Label(BuiltInReviewCopy.text("material.unavailable"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if context.group.hasUnavailableMaterial ||
                LingroveNotebookCardMaterial.resolve(source: context.link.source, snapshot: content.scope) == nil {
                HStack(spacing: 10) {
                    Label(BuiltInReviewCopy.text(context.link.allowsUnavailableMaterial ? "material.retained" : "material.unavailable"),
                        systemImage: context.link.allowsUnavailableMaterial ? "archivebox" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(context.link.allowsUnavailableMaterial ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    if !context.link.allowsUnavailableMaterial {
                        Button(BuiltInReviewCopy.text("action.retain")) { session.retain(context) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("builtinReview.retain")
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    if let model = content.noteCards[context.card.cardId] { session.editNote(model) }
                    else { session.edit(card: context.card, link: context.link, selection: context.group.selection, basedOn: content) }
                } label: {
                    Label(BuiltInReviewCopy.text("action.edit"), systemImage: "pencil")
                }
                .disabled(source == nil && !context.link.allowsUnavailableMaterial)
                .accessibilityIdentifier("builtinReview.edit." + context.card.cardId)

                if let model = content.noteCards[context.card.cardId] {
                    Button {
                        session.editNoteType(model.noteType)
                    } label: {
                        Label(String(localized: "Card templates", table: "Vocabulary"), systemImage: "rectangle.stack")
                    }
                }

                if let undo = session.undoAction(cardID: context.card.cardId, basedOn: content) {
                    Button {
                        session.undo(undo)
                    } label: {
                        Label(BuiltInReviewCopy.text("action.undo"), systemImage: "arrow.uturn.backward")
                    }
                    .accessibilityIdentifier("builtinReview.undo." + context.card.cardId)
                }

                Spacer()

                if source != nil, session.onOpenSource != nil {
                    Button(BuiltInReviewCopy.text("action.source"), systemImage: "arrow.up.forward.square") {
                        session.openSource(context)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
        )
    }
}
