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
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.noteType.templates.first { $0.id == model.templateID }?.name ?? model.noteType.name)
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(BuiltInReviewCopy.text("action.source")) { session.openSource(context) }
                Button(String(localized: "Card templates", table: "Vocabulary")) { session.editNoteType(model.noteType) }
            }.padding(.horizontal, 24).padding(.vertical, 12)
            if let rendered {
                ReviewNoteWebView(html: answer ? rendered.backHTML : rendered.frontHTML, css: rendered.css, images: imageMap)
                    .accessibilityIdentifier(answer ? "builtinReview.answer" : "builtinReview.question")
            } else {
                ContentUnavailableView(BuiltInReviewCopy.text("material.unavailable"), systemImage: "exclamationmark.triangle")
            }
        }
    }
}
