import LingroveNotebook
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
    var pruneImports = true
    var title: String?
    @State private var failure: String?
    @State private var operation: Task<Void, Never>?

    @StateObject private var editor = VocabularyRichTextEditorModel()
    @State private var images: [String: NSImage] = [:]

    var body: some View {
        Section(title ?? String(localized: "Sense explanation", table: "Vocabulary")) {
            HStack {
                Picker(String(localized: "Text style", table: "Vocabulary"), selection: Binding(
                    get: { editor.style }, set: { editor.setStyle($0) })) {
                    Text(String(localized: "Paragraph", table: "Vocabulary")).tag(VocabularyTextContent.Style.paragraph)
                    Text(String(localized: "Heading", table: "Vocabulary")).tag(VocabularyTextContent.Style.heading)
                    Text(String(localized: "Bullet", table: "Vocabulary")).tag(VocabularyTextContent.Style.bullet)
                }.labelsHidden().frame(width: 130).disabled(editor.selectedImage != nil)
                Toggle(isOn: Binding(get: { editor.bold }, set: { _ in editor.toggle(.boldFontMask) })) {
                    Image(systemName: "bold")
                }.toggleStyle(.button).help(String(localized: "Bold", table: "Vocabulary")).disabled(editor.selectedImage != nil)
                Toggle(isOn: Binding(get: { editor.italic }, set: { _ in editor.toggle(.italicFontMask) })) {
                    Image(systemName: "italic")
                }.toggleStyle(.button).help(String(localized: "Italic", table: "Vocabulary")).disabled(editor.selectedImage != nil)
                Spacer()
                Button(action: chooseImage) {
                    Label(String(localized: "Add image", table: "Vocabulary"), systemImage: "photo.badge.plus")
                }
                Button { editor.view?.importPasteboard(.general) } label: {
                    Label(String(localized: "Paste image", table: "Vocabulary"), systemImage: "doc.on.clipboard")
                }
                if importing { ProgressView().controlSize(.small) }
            }.buttonStyle(.borderless).disabled(importing)
            VocabularyRichTextEditor(blocks: $blocks, images: images, model: editor,
                enabled: !importing, importContent: importContent)
                .frame(minHeight: 280, idealHeight: 320, maxHeight: 420)
            if let image = editor.selectedImage {
                TextField(String(localized: "Caption", table: "Vocabulary"), text: Binding(
                    get: { editor.selectedImage?.caption ?? image.caption }, set: { editor.setCaption($0) }), axis: .vertical)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .task(id: VocabularyContentPolicy.images(blocks).map(\.filename).joined(separator: "|")) {
            for reference in VocabularyContentPolicy.images(blocks) where images[reference.filename] == nil {
                let data: Data?
                if let staged = importedImages[reference.filename] { data = staged }
                else { data = await store.image(reference) }
                guard !Task.isCancelled else { return }
                if let data, let image = NSImage(data: data) { images[reference.filename] = image }
            }
        }
        .onDisappear { operation?.cancel() }
        // Staged images live for the draft, including native undo of an image deletion.
        // The archive imports only references present at Save; Cancel publishes no media.
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
                  let bytes = image.tiffRepresentation else { return }
            importContent(NSAttributedString(attachment: NSTextAttachment(data: bytes, ofType: UTType.tiff.identifier)))
        }
    }

    /// Native paste is normalized as one operation before changing the buffer. Images retain
    /// the existing bounded preparation service and value-draft lifetime, never filesystem URLs.
    private func importContent(_ input: NSAttributedString) {
        guard !importing else { return }
        importing = true; failure = nil
        let baseline = editor.document
        operation = Task { @MainActor in
            defer { importing = false; operation = nil }
            do {
                let value = NSMutableAttributedString(attributedString: input)
                var attachments: [(NSRange, NSTextAttachment)] = []
                value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, range, _ in
                    if let attachment = attachment as? NSTextAttachment { attachments.append((range, attachment)) }
                }
                for (range, attachment) in attachments.reversed() {
                    if attachment is VocabularyRichTextAttachment { continue }
                    let bytes = attachment.fileWrapper?.regularFileContents ?? attachment.contents
                        ?? (attachment.attachmentCell as? NSTextAttachmentCell)?.image?.tiffRepresentation
                    guard let bytes else { throw VocabularyError.invalidContent }
                    let prepared = try await store.prepareImage(bytes)
                    try Task.checkCancellation()
                    importedImages[prepared.reference.filename] = prepared.data
                    let image = NSImage(data: prepared.data); images[prepared.reference.filename] = image
                    let native = VocabularyRichTextAttachment(id: UUID(), reference: prepared.reference, caption: "", image: image)
                    value.replaceCharacters(in: range, with: NSAttributedString(attachment: native))
                }
                try Task.checkCancellation()
                guard editor.document == baseline else { return }
                // Fonts become semantic marks. The same codec strips foreign attributes on save.
                value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) { font, range, _ in
                    let font = font as? NSFont ?? VocabularyRichTextCodec.bodyFont
                    let traits = NSFontManager.shared.traits(of: font)
                    let heading = value.attribute(VocabularyRichTextCodec.styleKey, at: range.location, effectiveRange: nil) as? String == "heading"
                    value.addAttributes([.font: VocabularyRichTextCodec.font(bold: traits.contains(.boldFontMask),
                        italic: traits.contains(.italicFontMask), heading: heading), .foregroundColor: NSColor.labelColor], range: range)
                }
                if !attachments.isEmpty {
                    // Images occupy their own paragraph inside the single continuous editor.
                    // This is document layout, not an additional field or editing surface.
                    var imageRanges: [NSRange] = []
                    value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, range, _ in
                        if attachment != nil { imageRanges.append(range) }
                    }
                    for range in imageRanges.reversed() {
                        if NSMaxRange(range) == value.length || (value.string as NSString).character(at: NSMaxRange(range)) != 10 {
                            value.insert(NSAttributedString(string: "\n", attributes: VocabularyRichTextCodec.defaults()), at: NSMaxRange(range))
                        }
                        if range.location == 0 || (value.string as NSString).character(at: range.location - 1) != 10 {
                            value.insert(NSAttributedString(string: "\n", attributes: VocabularyRichTextCodec.defaults()), at: range.location)
                        }
                    }
                }
                // Use the same portable subset immediately, so pasted attributes cannot look
                // supported in the editor and then disappear after Save/reopen.
                let normalized = VocabularyRichTextCodec.blocks(value)
                editor.insert(VocabularyRichTextCodec.attributed(normalized, images: images))
            } catch is CancellationError { } catch {
                failure = String(localized: "Unable to add this image. Try a smaller image.", table: "Vocabulary")
            }
        }
    }
}
