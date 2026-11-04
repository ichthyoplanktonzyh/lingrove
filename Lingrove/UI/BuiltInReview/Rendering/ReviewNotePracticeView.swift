import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// Practice adapts one pinned question to the reusable web renderer. The session still owns
/// keyboard admission, ratings, playback and source navigation; preview uses the same renderer.
struct ReviewNotePracticeView: View {
    @ObservedObject var session: BuiltInReviewSession
    let context: BuiltInReviewCardContext
    let model: NotebookReviewNoteCard
    let answer: Bool

    private var rendered: ReviewRenderedCard? { try? model.render(in: context.snapshot) }
    private var imageMap: [String: Data] {
        var result: [String: Data] = [:]
        guard let source = BuiltInReviewSource.value(context.group.selection, in: context.snapshot) else { return result }
        for image in VocabularyContentPolicy.images(source.sense.content ?? []) {
            let id = LingroveNotebookCardMaterial.mediaAssetID(reference: .init(image: image), workspaceID: context.snapshot.workspaceId)
            if let saved = session.images.first(where: { $0.id == id }) { result[image.filename] = saved.data }
        }
        return result
    }
    private var templateName: String {
        model.noteType.templates.first { $0.id == model.templateID }?.name ?? model.noteType.name
    }

    var body: some View {
        LingroveReadableContentLayout(maxWidth: 840, horizontalPadding: 24) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LingroveBrand.accent)
                        Text(templateName)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(LingroveBrand.accent.opacity(0.10))
                    )

                    Text(String(localized: answer ? "Back" : "Front", table: "ReviewCards"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )

                    Spacer()

                    if session.canSpeak {
                        Button {
                            session.speak(context, answer: answer)
                        } label: {
                            Image(systemName: session.isSpeaking(context, answer: answer) ? "speaker.wave.2.fill" : "speaker.wave.2")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        session.openSource(context)
                    } label: {
                        Label(BuiltInReviewCopy.text("action.source"), systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        session.editNoteType(model.noteType)
                    } label: {
                        Label(String(localized: "Card templates", table: "Vocabulary"), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let rendered {
                    ReviewNoteWebView(html: answer ? rendered.backHTML : rendered.frontHTML, css: rendered.css, images: imageMap)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
                        }
                        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
                        .accessibilityIdentifier(answer ? "builtinReview.answer" : "builtinReview.question")
                } else {
                    ContentUnavailableView(BuiltInReviewCopy.text("material.unavailable"), systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.vertical, 16)
        }
    }
}
