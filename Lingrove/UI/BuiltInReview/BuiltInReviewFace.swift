import AppKit
import LingroveNotebook
import LingroveNotebookEngine
import LingroveNotebookUI
import SwiftUI

/// A generated face renders the same ordered neutral parts as preparation. Authored or retained
/// faces keep their saved Markdown. All media comes from fenced local bytes; opening a question
/// neither loads a remote image nor regenerates a recording through the speech provider.
struct BuiltInReviewFace: View {
    let text: String
    let images: [BuiltInReviewSavedImage]
    var material: [ReviewResolvedPart]?
    var workspaceID: String?
    var audio: [BuiltInReviewSavedAudio] = []
    var onPlayAudio: ((BuiltInReviewSavedAudio) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let material {
                ForEach(material.indices, id: \.self) { index in
                    switch material[index] {
                    case let .text(value): textView(value)
                    case let .blocks(blocks):
                        ForEach(blocks) { block in
                            switch block.content {
                            case let .text(value): VocabularyTextBlockView(content: value, font: .system(size: 17))
                            case let .image(reference, caption):
                                if let workspaceID {
                                    let id = LingroveNotebookCardMaterial.mediaAssetID(reference: .init(image: reference),
                                        workspaceID: workspaceID)
                                    imageView(id: id)
                                }
                                if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                        }
                    case let .audio(kind):
                        if let saved = audio.first(where: { $0.kind == kind }) { audioButton(saved) } else {
                            Label(BuiltInReviewCopy.text("material.audioUnavailable"), systemImage: "speaker.slash")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(BuiltInReviewText.attributed(text))
                    .font(.title3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(images.filter { referenced.contains($0.id) }) { image in imageView(id: image.id) }
                ForEach(audio.filter { referenced.contains($0.id) }) { audioButton($0) }
                if !referenced.isSubset(of: Set(images.map(\.id) + audio.map(\.id))) {
                    Label(BuiltInReviewCopy.text("material.imageUnavailable"), systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func textView(_ value: String) -> some View {
        Text(value).font(.title3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func imageView(id: String) -> some View {
        if let saved = images.first(where: { $0.id == id }), let native = NSImage(data: saved.data) {
            Image(nsImage: native).resizable().scaledToFit().frame(maxHeight: 280)
                .accessibilityLabel(BuiltInReviewCopy.text("material.image"))
        } else {
            Label(BuiltInReviewCopy.text("material.imageUnavailable"), systemImage: "photo")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func audioButton(_ saved: BuiltInReviewSavedAudio) -> some View {
        Button { onPlayAudio?(saved) } label: { Label(saved.kind.label, systemImage: "speaker.wave.2") }
            .buttonStyle(.bordered).disabled(onPlayAudio == nil)
            .accessibilityIdentifier("builtinReview.audio." + saved.kind.rawValue)
    }

    private var referenced: Set<String> { managedMediaAssetIdsReferencedInMarkdown(text: text) }
}
