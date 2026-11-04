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

    private var answeredCount: Int {
        session.practice?.answered ?? 0
    }

    private var sessionProgress: Double {
        let total = answeredCount + remaining
        guard total > 0 else { return 0 }
        return Double(answeredCount) / Double(total)
    }

    var body: some View {
        Group {
            if let context = session.practice?.phase.context {
                VStack(spacing: 0) {
                    practiceHeader
                    Divider()
                    if let model = context.action.noteCards[context.card.cardId] {
                        ReviewNotePracticeView(session: session, context: context, model: model, answer: isAnswerVisible)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LingroveReadableContentLayout(maxWidth: lingroveReadableContentMaxWidth, horizontalPadding: 24) {
                                    activeCard(context).padding(.vertical, 24)
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
                            .background(.bar)
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

    private var practiceHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Label(scopeTitle, systemImage: "rectangle.stack.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(BuiltInReviewCopy.text("session.answered") + ": " + answeredCount.formatted())
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .foregroundStyle(LingroveBrand.accent)
                        Text(BuiltInReviewCopy.text("count.ready") + ": " + remaining.formatted())
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    Capsule()
                        .fill(LingroveBrand.accent)
                        .frame(width: max(6, geo.size.width * sessionProgress))
                        .animation(.easeInOut(duration: 0.22), value: sessionProgress)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
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
        ScrollView {
            LingroveReadableContentLayout(maxWidth: 640, horizontalPadding: 24) {
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.14))
                            .frame(width: 68, height: 68)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.green)
                    }

                    VStack(spacing: 6) {
                        Text(BuiltInReviewCopy.text("session.finished"))
                            .font(.title2.weight(.bold))
                        Text(scopeTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 10) {
                        LabeledContent(BuiltInReviewCopy.text("session.answered"), value: answeredCount.formatted())
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                        if let nextDue {
                            Divider()
                            LabeledContent(BuiltInReviewCopy.text("session.nextDue"),
                                value: nextDue.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 360)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
                    }

                    HStack(spacing: 12) {
                        Button(BuiltInReviewCopy.text("action.home")) { session.endPractice() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityIdentifier("builtinReview.completed.home")
                        if session.onOpenProgress != nil {
                            Button(BuiltInReviewCopy.text("action.progress")) { session.onOpenProgress?() }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .accessibilityIdentifier("builtinReview.completed.progress")
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
                }
                .padding(.vertical, 36)
            }
        }
        .accessibilityIdentifier("builtinReview.completed")
    }

    private func activeCard(_ context: BuiltInReviewCardContext) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 8) {
                    Label(context.card.tags.isEmpty ? String(localized: "No tags", table: "ReviewCards")
                        : context.card.tags.joined(separator: ", "), systemImage: "tag")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                    Label {
                        Text(BuiltInReviewCopy.text("count.cardReviews") + ": " + context.card.reps.formatted())
                    } icon: { Image(systemName: "arrow.clockwise") }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .layoutPriority(1)

                Spacer(minLength: 12)

                if session.onOpenSource != nil, BuiltInReviewSource.value(context.group.selection, in: context.snapshot) != nil {
                    Button { session.openSource(context) } label: {
                        Label(BuiltInReviewCopy.text("action.source"), systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("builtinReview.practice.source")
                }

                Button {
                    session.edit(card: context.card, link: context.link, selection: context.group.selection, basedOn: content)
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Edit card", table: "ReviewCards"))
                    .help(String(localized: "Edit card", table: "ReviewCards"))
                    .accessibilityIdentifier("builtinReview.practice.edit")
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
