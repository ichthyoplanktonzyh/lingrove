import LingroveNotebook
// Card structure adapted from Nibomo ReviewView.swift; Copyright (c) 2026 Kirill Markin (MIT).
// License: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_REVIEW_ACCOUNT_UI_REUSE.md.
import LingroveNotebookEngine
import SwiftUI

/// This scrolling card column borrows one frozen question from the app-owned session. The
/// answer bar stays outside the scroller, while source, image, selection and speech actions
/// continue to use that same question identity rather than a fresh repository lookup.
struct BuiltInReviewPracticeView: View {
    @ObservedObject var session: BuiltInReviewSession
    let content: NotebookBuiltInReviewSnapshot
    @State private var selection: LingroveReviewTextSelection?

    private var isAnswerVisible: Bool {
        if case .answer = session.practice?.phase { return true }
        return false
    }

    var body: some View {
        Group {
            if let context = session.practice?.phase.context {
                VStack(spacing: 0) {
                    HStack {
                        Text(scopeTitle).lineLimit(1)
                        Spacer()
                        Text(BuiltInReviewCopy.text("session.answered") + ": " + (session.practice?.answered ?? 0).formatted())
                        Text(BuiltInReviewCopy.text("count.ready") + ": " + remaining.formatted())
                    }.font(.callout).foregroundStyle(.secondary).monospacedDigit().padding(.horizontal, 24).padding(.vertical, 12)
                    if let model = context.action.noteCards[context.card.cardId] {
                        ReviewNotePracticeView(session: session, context: context, model: model, answer: isAnswerVisible)
                    } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LingroveReadableContentLayout(maxWidth: lingroveReadableContentMaxWidth, horizontalPadding: 20) {
                                activeCard(context).padding(.vertical, 20)
                            }
                        }
                        .onChange(of: isAnswerVisible) { _, visible in
                            if visible { proxy.scrollTo("back", anchor: .top) }
                        }
                        .onChange(of: context.card.cardId) { _, _ in proxy.scrollTo("front", anchor: .top) }
                    }
                    }
                    Divider()
                    let options = try? lingroveMakeReviewAnswerOptions(card: context.card,
                        schedulerSettings: context.schedulerSettings, now: Date())
                    if !isAnswerVisible || options != nil {
                        LingroveReviewAnswerControls(options: isAnswerVisible ? options : nil,
                            onReveal: session.reveal, onRate: session.rate)
                    } else {
                        Text(BuiltInReviewCopy.text("error.write")).foregroundStyle(.red).padding()
                    }
                }
            } else if case .finished = session.practice?.phase {
                completion
            } else {
                BuiltInReviewOverviewView(session: session, content: content)
            }
        }
        .disabled(session.isBusy)
        .sheet(item: $selection) { LingroveReviewTextSelectionSheet(selection: $0) }
        .accessibilityIdentifier("builtinReview.practice")
    }

    private var remaining: Int { session.dueCards(selection: session.practice?.selection, in: content).count }

    private var scopeTitle: String {
        guard let selection = session.practice?.selection else { return BuiltInReviewCopy.text("session.todayScope") }
        return BuiltInReviewSource.value(selection, in: content.scope)?.entry.expression ?? BuiltInReviewCopy.text("session.selectedScope")
    }

    private var nextDue: Date? {
        content.review.groups.values.filter { group in
            group.status == .active && !group.hasUnavailableMaterial &&
                (session.practice?.selection == nil || group.selection.senseID == session.practice?.selection?.senseID)
        }.flatMap(\.cards).compactMap { $0.dueAt.flatMap { parseIsoTimestamp(value: $0) } }.min()
    }

    private var completion: some View {
        ContentUnavailableView {
            Label(BuiltInReviewCopy.text("session.finished"), systemImage: "checkmark.circle")
        } description: {
            VStack(spacing: 10) {
                Text(scopeTitle)
                LabeledContent(BuiltInReviewCopy.text("session.answered"), value: (session.practice?.answered ?? 0).formatted())
                if let nextDue {
                    LabeledContent(BuiltInReviewCopy.text("session.nextDue"),
                        value: nextDue.formatted(date: .abbreviated, time: .shortened))
                }
            }.frame(maxWidth: 360)
        } actions: {
            HStack {
                Button(BuiltInReviewCopy.text("action.home")) { session.endPractice() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("builtinReview.completed.home")
                if session.onOpenProgress != nil {
                    Button(BuiltInReviewCopy.text("action.progress")) { session.onOpenProgress?() }
                        .accessibilityIdentifier("builtinReview.completed.progress")
                }
            }
        }.accessibilityIdentifier("builtinReview.completed")
    }

    private func activeCard(_ context: BuiltInReviewCardContext) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 12) {
                    Label(context.card.tags.isEmpty ? String(localized: "No tags", table: "ReviewCards")
                        : context.card.tags.joined(separator: ", "), systemImage: "tag")
                    Label {
                        Text(BuiltInReviewCopy.text("count.cardReviews") + ": " + context.card.reps.formatted())
                    } icon: { Image(systemName: "arrow.clockwise") }
                }.layoutPriority(1)
                Spacer(minLength: 12)
                Button {
                    session.edit(card: context.card, link: context.link, selection: context.group.selection, basedOn: content)
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.bordered).accessibilityLabel(String(localized: "Edit card", table: "ReviewCards"))
                    .help(String(localized: "Edit card", table: "ReviewCards"))
                    .accessibilityIdentifier("builtinReview.practice.edit")
            }.font(.subheadline).foregroundStyle(.secondary)
            if session.onOpenSource != nil, BuiltInReviewSource.value(context.group.selection, in: context.snapshot) != nil {
                Button { session.openSource(context) } label: {
                    Label(BuiltInReviewCopy.text("action.source"), systemImage: "arrow.up.forward.square")
                }.buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("builtinReview.practice.source")
            }
            face(context, answer: false).id("front")
            if isAnswerVisible { face(context, answer: true).id("back") }
        }
    }

    private func face(_ context: BuiltInReviewCardContext, answer: Bool) -> some View {
        let title = String(localized: answer ? "Back" : "Front", table: "ReviewCards")
        let text = answer ? context.card.backText : context.card.frontText
        return LingroveReviewCardSideView(label: title, content: session.images, sourceText: text,
            onSelectText: { selection = .init(title: title, sourceText: text) },
            isSpeechPlaying: session.isSpeaking(context, answer: answer),
            onToggleSpeech: { session.speak(context, answer: answer) },
            showsSpeechButton: session.canSpeak, surfaceStyle: answer ? .back : .front,
            material: session.resolvedParts(context, answer: answer), workspaceID: context.snapshot.workspaceId,
            audio: session.savedAudio, onPlayAudio: { session.playSavedAudio($0, context: context) })
    }
}
