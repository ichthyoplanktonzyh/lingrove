import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// This view edits value drafts owned by VocabularyEntryEditor. It borrows the process store
/// for background normalization but never writes the archive itself. Save passes only referenced
/// draft bytes to the archive transaction; Cancel simply releases this window's memory.
struct VocabularyContentEditor: View {
    @Binding var blocks: [VocabularyContentBlock]
    @Binding var importedImages: [String: Data]
    let store: VocabularyStore
    @Binding var importing: Bool
    @State private var failure: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        Section(String(localized: "Sense explanation", table: "Vocabulary")) {
            ForEach($blocks) { $block in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if case .text = block.content {
                            Picker(String(localized: "Text style", table: "Vocabulary"), selection: text($block).style) {
                                Text(String(localized: "Paragraph", table: "Vocabulary")).tag(VocabularyTextContent.Style.paragraph)
                                Text(String(localized: "Heading", table: "Vocabulary")).tag(VocabularyTextContent.Style.heading)
                                Text(String(localized: "Bullet", table: "Vocabulary")).tag(VocabularyTextContent.Style.bullet)
                            }.labelsHidden().frame(width: 130)
                            Toggle(isOn: text($block).bold) { Image(systemName: "bold") }.toggleStyle(.button)
                                .help(String(localized: "Bold", table: "Vocabulary"))
                            Toggle(isOn: text($block).italic) { Image(systemName: "italic") }.toggleStyle(.button)
                                .help(String(localized: "Italic", table: "Vocabulary"))
                        }
                        Spacer()
                        Button { move(block.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(blocks.first?.id == block.id).help(String(localized: "Move up", table: "Vocabulary"))
                        Button { move(block.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(blocks.last?.id == block.id).help(String(localized: "Move down", table: "Vocabulary"))
                        Button(role: .destructive) { blocks.removeAll { $0.id == block.id } } label: { Image(systemName: "trash") }
                            .help(String(localized: "Delete", table: "Vocabulary"))
                    }.buttonStyle(.borderless)
                    switch block.content {
                    case .text:
                        TextEditor(text: text($block).text).frame(minHeight: 80)
                    case let .image(reference, _):
                        VocabularyImageView(reference: reference, store: store, draftData: importedImages[reference.filename])
                        TextField(String(localized: "Caption", table: "Vocabulary"), text: caption($block), axis: .vertical)
                    }
                }.padding(.vertical, 4)
            }
            HStack {
                Button { blocks.append(.init(content: .text(.init()))) } label: {
                    Label(String(localized: "Add text", table: "Vocabulary"), systemImage: "text.badge.plus")
                }
                Button(action: chooseImage) {
                    Label(String(localized: "Add image", table: "Vocabulary"), systemImage: "photo.badge.plus")
                }
                Button(action: pasteImage) {
                    Label(String(localized: "Paste image", table: "Vocabulary"), systemImage: "doc.on.clipboard")
                }
                if importing { ProgressView().controlSize(.small) }
            }.disabled(importing || blocks.count >= 64)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: nil, perform: importProviders)
        .onPasteCommand(of: [.png, .tiff, .jpeg]) { providers in _ = importProviders(providers) }
        .onDisappear { operation?.cancel() }
        .onChange(of: blocks) { _, value in
            let retained = Set(VocabularyContentPolicy.images(value).map(\.filename))
            importedImages = importedImages.filter { retained.contains($0.key) }
        }
    }

    private func text(_ block: Binding<VocabularyContentBlock>) -> Binding<VocabularyTextContent> {
        Binding(get: { if case let .text(value) = block.wrappedValue.content { value } else { .init() } },
                set: { block.wrappedValue.content = .text($0) })
    }
    private func caption(_ block: Binding<VocabularyContentBlock>) -> Binding<String> {
        Binding(get: { if case let .image(_, value) = block.wrappedValue.content { value } else { "" } }, set: { value in
            if case let .image(reference, _) = block.wrappedValue.content { block.wrappedValue.content = .image(reference, caption: value) }
        })
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }), blocks.indices.contains(index + offset) else { return }
        blocks.swapAt(index, index + offset)
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK, let url = panel.url { importImage(url: url) } }
    }
    private func pasteImage() {
        guard let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) ??
            NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) else { return }
        importImage(data: data)
    }
    private func importProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !importing, blocks.count < 64, let provider = providers.first else { return false }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier :
            provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
        guard let type else { return false }
        importImage(provider: provider, type: type); return true
    }
    private func importImage(url: URL? = nil, data: Data? = nil, provider: NSItemProvider? = nil, type: String? = nil) {
        guard !importing, blocks.count < 64 else { return }
        importing = true; failure = nil
        operation = Task {
            defer { importing = false; operation = nil }
            do {
                let prepared: VocabularyPreparedImage
                if let provider, let type {
                    let bytes = try await VocabularyImageTransfer.load(provider, type: type)
                    try Task.checkCancellation()
                    if type == UTType.fileURL.identifier, let url = URL(dataRepresentation: bytes, relativeTo: nil) {
                        prepared = try await store.prepareImage(at: url)
                    } else { prepared = try await store.prepareImage(bytes) }
                } else if let url { prepared = try await store.prepareImage(at: url) } else if let data {
                    prepared = try await store.prepareImage(data)
                } else { return }
                try Task.checkCancellation()
                let block = VocabularyContentBlock(content: .image(prepared.reference, caption: ""))
                try VocabularyContentPolicy.validate(blocks + [block])
                importedImages[prepared.reference.filename] = prepared.data
                blocks.append(block)
            } catch is CancellationError { } catch {
                failure = String(localized: "Unable to add this image. Try a smaller image.", table: "Vocabulary")
            }
        }
    }
}
