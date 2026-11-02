import Foundation
import AppKit
import LingroveNotebookEngine
import SwiftUI

/// Practice renders the pinned Card without owning scheduling. Reveal changes window state;
/// rating submits the original snapshot to the common engine and then requests its next queue.
struct BuiltInReviewPracticeView: View {
    @ObservedObject var session: BuiltInReviewSession
    let content: NotebookBuiltInReviewSnapshot

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(BuiltInReviewCopy.text("action.finish"), systemImage: "chevron.left") { session.endPractice() }
                Spacer()
                Text(BuiltInReviewCopy.text("session.answered"))
                Text(session.practice?.answered ?? 0, format: .number).monospacedDigit()
                if let undo = session.latestUndo {
                    Button(BuiltInReviewCopy.text("action.undo"), systemImage: "arrow.uturn.backward") { session.undo(undo) }
                        .accessibilityIdentifier("builtinReview.session.undo")
                }
            }.padding(20).disabled(session.isBusy)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let context = session.practice?.phase.context {
                        question(context)
                        if case .answer = session.practice?.phase { answer(context) } else {
                            Button(BuiltInReviewCopy.text("action.reveal"), systemImage: "rectangle.on.rectangle") { session.reveal() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .accessibilityIdentifier("builtinReview.reveal")
                        }
                    } else {
                        ContentUnavailableView {
                            Label(BuiltInReviewCopy.text("session.finished"), systemImage: "checkmark.circle")
                        } description: { Text(BuiltInReviewCopy.text("session.scheduled")) }
                        actions: {
                            Button(BuiltInReviewCopy.text("action.finish")) { session.endPractice(); session.reload() }
                        }
                    }
                }.padding(28).frame(maxWidth: 900, alignment: .leading).disabled(session.isBusy)
            }
            Divider()
            Text(BuiltInReviewCopy.text("keyboard.hint")).font(.caption).foregroundStyle(.secondary).padding(12)
        }.accessibilityIdentifier("builtinReview.practice")
    }

    private func question(_ context: BuiltInReviewCardContext) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(BuiltInReviewCopy.text("field.prompt")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if session.onOpenSource != nil,
                   BuiltInReviewSource.value(context.group.selection, in: context.snapshot) != nil {
                    Button(BuiltInReviewCopy.text("action.source"), systemImage: "arrow.up.forward.square") {
                        session.openSource(context)
                    }
                }
                speaker(context, answer: false)
            }
            BuiltInReviewFace(text: context.card.frontText, images: session.images)
                .accessibilityIdentifier("builtinReview.question")
        }
    }

    private func answer(_ context: BuiltInReviewCardContext) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            HStack {
                Text(BuiltInReviewCopy.text("field.answer")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                speaker(context, answer: true)
            }
            BuiltInReviewFace(text: context.card.backText, images: session.images)
                .accessibilityIdentifier("builtinReview.answer")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 70), spacing: 10), count: 4), spacing: 10) {
                ForEach(ReviewRating.allCases) { rating in
                    Button { session.rate(rating) } label: {
                        VStack(spacing: 6) {
                            Text(BuiltInReviewCopy.rating(rating)).font(.headline)
                            if let date = try? computeReviewSchedule(card: context.card, settings: context.schedulerSettings,
                                                                   rating: rating, now: Date()).dueAt {
                                Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(String(rating.rawValue + 1)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.bordered).tint(rating == .good ? .accentColor : .secondary)
                        .accessibilityIdentifier("builtinReview.rate." + String(rating.rawValue + 1))
                }
            }
        }
    }

    @ViewBuilder
    private func speaker(_ context: BuiltInReviewCardContext, answer: Bool) -> some View {
        if session.canSpeak {
            Button { session.speak(context, answer: answer) } label: {
                Image(systemName: session.isSpeaking(context, answer: answer) ? "stop.circle" : "speaker.wave.2")
            }.accessibilityLabel(BuiltInReviewCopy.text(session.isSpeaking(context, answer: answer) ? "action.stopSpeech" : "action.speak"))
        }
    }
}

/// SwiftUI Text parses saved Markdown without a web view. Managed images use validated local
/// bytes from IO; a remote image destination is never loaded as a side effect of showing a face.
struct BuiltInReviewFace: View {
    let text: String
    let images: [BuiltInReviewSavedImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(BuiltInReviewText.attributed(text))
                .font(.title3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(images.filter { referenced.contains($0.id) }) { image in
                if let native = NSImage(data: image.data) {
                    Image(nsImage: native).resizable().scaledToFit().frame(maxHeight: 280)
                        .accessibilityLabel(BuiltInReviewCopy.text("material.image"))
                }
            }
            if !referenced.isSubset(of: Set(images.map(\.id))) {
                Label(BuiltInReviewCopy.text("material.imageUnavailable"), systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var referenced: Set<String> { managedMediaAssetIdsReferencedInMarkdown(text: text) }
}
