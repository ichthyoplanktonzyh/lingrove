import AppKit
import LingroveNotebookEngine
import SwiftUI

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
