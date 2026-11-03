// Card structure adapted from Nibomo ReviewView.swift; Copyright (c) 2026 Kirill Markin (MIT).
// License: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W3_UI_REUSE_MAP.md.
import LingroveNotebookEngine
import SwiftUI

/// Native binding for Nibomo’s card column and fixed bottom answer bar. The app-owned session
/// supplies one frozen question; these views only reveal, edit or submit that same question.
/// Speech and local images come from existing Lingrove services, never a new mobile store.
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
            } else {
                BuiltInReviewOverviewView(session: session, content: content)
            }
        }
        .disabled(session.isBusy)
        .sheet(item: $selection) { LingroveReviewTextSelectionSheet(selection: $0) }
        .accessibilityIdentifier("builtinReview.practice")
    }

    private func activeCard(_ context: BuiltInReviewCardContext) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 12) {
                    Label(context.card.tags.isEmpty ? String(localized: "No tags", table: "ReviewCards")
                        : context.card.tags.joined(separator: ", "), systemImage: "tag")
                    Label(context.card.reps.formatted(), systemImage: "arrow.clockwise")
                }.layoutPriority(1)
                Spacer(minLength: 12)
                Button {
                    session.edit(card: context.card, link: context.link, selection: context.group.selection, basedOn: content)
                } label: { Image(systemName: "pencil.circle.fill").font(.title3) }
                    .buttonStyle(.plain).accessibilityLabel(String(localized: "Edit card", table: "ReviewCards"))
                    .accessibilityIdentifier("builtinReview.practice.edit")
            }.font(.subheadline).foregroundStyle(.secondary)
            if session.onOpenSource != nil, BuiltInReviewSource.value(context.group.selection, in: context.snapshot) != nil {
                Button { session.openSource(context) } label: {
                    Label(BuiltInReviewCopy.text("action.source"), systemImage: "arrow.up.forward.square")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
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
            showsSpeechButton: session.canSpeak, surfaceStyle: answer ? .back : .front)
    }
}
