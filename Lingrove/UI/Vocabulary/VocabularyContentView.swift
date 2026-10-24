import SwiftUI

/// Sense reading and the editor share the same native block presentation. An image view loads
/// only while visible, cancels when replaced and never decodes the original imported full-size
/// file: the archive has already normalized it to the bounded notebook representation.
struct VocabularyContentView: View {
    let blocks: [VocabularyContentBlock]
    let store: VocabularyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                switch block.content {
                case let .text(value):
                    Text((value.style == .bullet ? "• " : "") + value.text)
                        .font(value.style == .heading ? .headline : .body)
                        .bold(value.bold).italic(value.italic).textSelection(.enabled)
                case let .image(image, caption):
                    VocabularyImageView(reference: image, store: store)
                        .accessibilityLabel(caption.isEmpty ? String(localized: "Image", table: "Vocabulary") : caption)
                    if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A visible row owns its decoded image and optional enlargement sheet. Draft bytes are kept
/// in the editor, not the shared store; cancelling a draft cannot publish unsaved media.
struct VocabularyImageView: View {
    let reference: VocabularyImageReference
    @ObservedObject var store: VocabularyStore
    var draftData: Data?
    @State private var image: NSImage?
    @State private var loaded = false
    @State private var enlarged = false

    var body: some View {
        Group {
            if let image {
                Button { enlarged = true } label: {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280)
                }.buttonStyle(.plain).help(String(localized: "Enlarge image", table: "Vocabulary"))
            } else if loaded {
                Label(String(localized: "Image unavailable", table: "Vocabulary"), systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: reference.filename + store.mediaRevision.uuidString) {
            loaded = false; image = nil
            let data = await loadData()
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:)); loaded = true
        }
        .sheet(isPresented: $enlarged) {
            VStack {
                if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                Button(String(localized: "Close")) { enlarged = false }.keyboardShortcut(.cancelAction)
            }.padding().frame(width: 760, height: 580)
        }
    }

    private func loadData() async -> Data? {
        if let draftData { return draftData }
        return await store.image(reference)
    }
}
