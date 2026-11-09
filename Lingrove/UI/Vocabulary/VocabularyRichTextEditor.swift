import AppKit
import Combine
import LingroveNotebook
import SwiftUI

/// One editor-sheet session coordinates selection and commands for its single NSTextView.
/// The weak view reference cannot outlive the representable; only the parent's value draft
/// survives native callbacks. This object neither opens a database nor owns a save operation.
@MainActor
final class VocabularyRichTextEditorModel: ObservableObject {
    weak var view: VocabularyRichTextView?
    @Published var style: VocabularyTextContent.Style = .paragraph
    @Published var bold = false
    @Published var italic = false
    @Published var selectedImage: VocabularyRichTextAttachment?
    var document: [VocabularyContentBlock] = []
    var publish: (([VocabularyContentBlock]) -> Void)?
    var importContent: ((NSAttributedString) -> Void)?
    var isApplying = false
    var images: [String: NSImage] = [:]

    func changed() {
        guard !isApplying, let view, !view.hasMarkedText() else { return }
        document = VocabularyRichTextCodec.blocks(view.attributedString())
        publish?(document)
        selectionChanged()
    }
    func selectionChanged() {
        guard let view, !isApplying else { return }
        let range = view.selectedRange()
        let attributes = range.location < (view.textStorage?.length ?? 0)
            ? view.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? [:] : view.typingAttributes
        let traits = NSFontManager.shared.traits(of: attributes[.font] as? NSFont ?? VocabularyRichTextCodec.bodyFont)
        bold = traits.contains(.boldFontMask); italic = traits.contains(.italicFontMask)
        style = VocabularyTextContent.Style(rawValue: attributes[VocabularyRichTextCodec.styleKey] as? String ?? "") ?? .paragraph
        selectedImage = range.length == 1 ? attributes[.attachment] as? VocabularyRichTextAttachment : nil
    }
    func toggle(_ trait: NSFontTraitMask) {
        guard selectedImage == nil, let view else { return }
        let range = view.selectedRange(), enable = trait == .boldFontMask ? !bold : !italic
        if range.length == 0 {
            var attributes = view.typingAttributes
            let font = attributes[.font] as? NSFont ?? VocabularyRichTextCodec.bodyFont
            attributes[.font] = enable ? NSFontManager.shared.convert(font, toHaveTrait: trait) : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            view.typingAttributes = attributes
            bold = NSFontManager.shared.traits(of: attributes[.font] as? NSFont ?? font).contains(.boldFontMask)
            italic = NSFontManager.shared.traits(of: attributes[.font] as? NSFont ?? font).contains(.italicFontMask)
        } else {
            let value = NSMutableAttributedString(attributedString: view.attributedString().attributedSubstring(from: range))
            value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) { font, selection, _ in
                let font = font as? NSFont ?? VocabularyRichTextCodec.bodyFont
                value.addAttribute(.font, value: enable ? NSFontManager.shared.convert(font, toHaveTrait: trait)
                    : NSFontManager.shared.convert(font, toNotHaveTrait: trait), range: selection)
            }
            view.replace(range, with: value, selection: range)
        }
        view.window?.makeFirstResponder(view)
    }
    func setStyle(_ style: VocabularyTextContent.Style) {
        guard let view else { self.style = style; return }
        if view.string.isEmpty {
            self.style = style; view.typingAttributes = VocabularyRichTextCodec.defaults(style: style)
            if style == .bullet {
                view.replace(NSRange(location: 0, length: 0), with: NSAttributedString(string: "• ", attributes: view.typingAttributes),
                    selection: NSRange(location: 2, length: 0))
            }
            view.window?.makeFirstResponder(view)
            return
        }
        let source = view.string as NSString, selected = view.selectedRange()
        let range = source.paragraphRange(for: selected)
        let value = NSMutableAttributedString(attributedString: view.attributedString().attributedSubstring(from: range))
        var positions: [NSRange] = [], cursor = 0
        while cursor < value.length {
            let paragraph = (value.string as NSString).paragraphRange(for: NSRange(location: cursor, length: 0))
            positions.append(paragraph); cursor = NSMaxRange(paragraph)
        }
        for paragraph in positions.reversed() {
            let text = (value.string as NSString).substring(with: paragraph)
            let hasMarker = text.hasPrefix("• ")
            var length = paragraph.length
            if hasMarker { value.deleteCharacters(in: NSRange(location: paragraph.location, length: 2)); length -= 2 }
            if style == .bullet {
                value.insert(NSAttributedString(string: "• ", attributes: VocabularyRichTextCodec.defaults(style: style)), at: paragraph.location)
                length += 2
            }
            let target = NSRange(location: paragraph.location, length: length)
            value.addAttribute(VocabularyRichTextCodec.styleKey, value: style.rawValue, range: target)
            value.enumerateAttribute(.font, in: target) { font, selection, _ in
                let traits = NSFontManager.shared.traits(of: font as? NSFont ?? VocabularyRichTextCodec.bodyFont)
                value.addAttribute(.font, value: VocabularyRichTextCodec.font(bold: style == .heading,
                    italic: traits.contains(.italicFontMask), heading: style == .heading), range: selection)
            }
        }
        func adjusted(_ position: Int) -> Int {
            var result = position
            for paragraph in positions where position >= paragraph.location {
                let original = (source.substring(with: range) as NSString).substring(with: paragraph)
                if original.hasPrefix("• ") { result -= min(2, position - paragraph.location) }
                if style == .bullet { result += 2 }
            }
            return result
        }
        let start = adjusted(selected.location - range.location)
        let end = adjusted(NSMaxRange(selected) - range.location)
        view.replace(range, with: value, selection: NSRange(location: range.location + start, length: max(0, end - start)))
        if selected.length == 0 { view.typingAttributes = VocabularyRichTextCodec.defaults(style: style) }
        self.style = style
        view.window?.makeFirstResponder(view)
    }
    func insert(_ content: NSAttributedString) {
        guard let view else { return }
        // The sheet disables user typing while normalizing pasted media. This synchronous
        // insertion owns the completed import and must pass NSTextView's editability check.
        let wasEditable = view.isEditable
        view.isEditable = true
        defer { view.isEditable = wasEditable }
        let selection = view.selectedRange()
        view.replace(selection, with: content, selection: NSRange(location: selection.location + content.length, length: 0))
        var typing = view.typingAttributes
        typing.removeValue(forKey: .attachment); typing.removeValue(forKey: VocabularyRichTextCodec.blockKey)
        view.typingAttributes = typing
        view.window?.makeFirstResponder(view)
    }
    func setCaption(_ caption: String) {
        guard let view, let image = selectedImage else { return }
        let replacement = VocabularyRichTextAttachment(id: image.contentID, reference: image.reference,
            caption: caption, image: images[image.reference.filename] ?? (image.attachmentCell as? NSTextAttachmentCell)?.image)
        let range = view.selectedRange()
        view.replace(range, with: NSAttributedString(attachment: replacement), selection: range)
    }
}

/// Native text input owns IME composition, selection and one undo stack. External rich paste
/// is handed to the sheet for image normalization before insertion; unsupported foreign
/// attributes never bypass the corpus's media registry or become persisted native objects.
@MainActor
final class VocabularyRichTextView: NSTextView {
    weak var editor: VocabularyRichTextEditorModel?
    func replace(_ range: NSRange, with replacement: NSAttributedString, selection: NSRange) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: replacement.string) else { return }
        // shouldChangeText registers the native undo record, including rich attributes.
        // A second manual inverse would restore attachments twice during one undo.
        storage.replaceCharacters(in: range, with: replacement)
        setSelectedRange(selection); didChangeText()
    }
    @objc func toggleBoldface(_ sender: Any?) { editor?.toggle(.boldFontMask) }
    @objc func toggleItalics(_ sender: Any?) { editor?.toggle(.italicFontMask) }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": editor?.toggle(.boldFontMask); return
            case "i": editor?.toggle(.italicFontMask); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
    private static let clipboardType = NSPasteboard.PasteboardType("io.ichthyoplanktonzyh.lingrove.rich-content")
    override func copy(_ sender: Any?) {
        super.copy(sender)
        let value = VocabularyRichTextCodec.blocks(attributedString().attributedSubstring(from: selectedRange()))
        if let data = try? JSONEncoder().encode(value) {
            NSPasteboard.general.addTypes([Self.clipboardType], owner: nil)
            NSPasteboard.general.setData(data, forType: Self.clipboardType)
        }
    }
    override func cut(_ sender: Any?) {
        copy(sender)
        let range = selectedRange()
        replace(range, with: NSAttributedString(string: ""), selection: NSRange(location: range.location, length: 0))
    }
    override func paste(_ sender: Any?) { importPasteboard(.general) }
    func importPasteboard(_ pasteboard: NSPasteboard) {
        if let data = pasteboard.data(forType: Self.clipboardType), data.count <= 16 * 1024 * 1024,
           let blocks = try? JSONDecoder().decode([VocabularyContentBlock].self, from: data),
           (try? VocabularyContentPolicy.validate(blocks)) != nil {
            editor?.importContent?(VocabularyRichTextCodec.attributed(blocks, images: editor?.images ?? [:])); return
        }
        for (type, format) in [(NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd), (.rtf, .rtf)] {
            if let data = pasteboard.data(forType: type), data.count <= 16 * 1024 * 1024,
               let value = try? NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil) {
                editor?.importContent?(value); return
            }
        }
        if let image = NSImage(pasteboard: pasteboard), let bytes = image.tiffRepresentation {
            editor?.importContent?(NSAttributedString(attachment: NSTextAttachment(data: bytes, ofType: "public.tiff"))); return
        }
        if let text = pasteboard.string(forType: .string) {
            editor?.importContent?(NSAttributedString(string: text, attributes: typingAttributes))
        }
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if sender.draggingSource as AnyObject? === self { return super.performDragOperation(sender) }
        let location = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: location), length: 0))
        importPasteboard(sender.draggingPasteboard); return true
    }
    override func unmarkText() {
        super.unmarkText()
        editor?.changed()
    }
    override func insertNewline(_ sender: Any?) {
        let style = editor?.style ?? .paragraph
        let paragraph = (string as NSString).paragraphRange(for: selectedRange())
        if style == .bullet, (string as NSString).substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines) == "•" {
            replace(paragraph, with: NSAttributedString(string: "", attributes: VocabularyRichTextCodec.defaults()),
                selection: NSRange(location: paragraph.location, length: 0))
            typingAttributes = VocabularyRichTextCodec.defaults(); editor?.style = .paragraph
            return
        }
        super.insertNewline(sender)
        typingAttributes = VocabularyRichTextCodec.defaults(style: style == .heading ? .paragraph : style)
        if style == .bullet { insertText("• ", replacementRange: selectedRange()) }
    }
}

/// This adapter reconciles saved value changes only when they differ from the native draft.
/// Normal typing never replaces textStorage, preserving marked text, caret and undo history.
struct VocabularyRichTextEditor: NSViewRepresentable {
    @Binding var blocks: [VocabularyContentBlock]
    let images: [String: NSImage]
    @ObservedObject var model: VocabularyRichTextEditorModel
    let enabled: Bool
    let importContent: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = VocabularyRichTextView(frame: .zero)
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = view
        view.isRichText = true; view.importsGraphics = true; view.allowsUndo = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.backgroundColor = .textBackgroundColor; view.textColor = .labelColor
        view.typingAttributes = VocabularyRichTextCodec.defaults()
        view.setAccessibilityIdentifier("vocabulary.explanation.editor")
        view.setAccessibilityLabel(String(localized: "Sense explanation", table: "Vocabulary"))
        view.editor = model; model.view = view; view.delegate = context.coordinator
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? VocabularyRichTextView else { return }
        model.publish = { blocks = $0 }; model.importContent = importContent; model.images = images
        view.isEditable = enabled
        if model.document != blocks || (view.string.isEmpty && !blocks.isEmpty) {
            guard !view.hasMarkedText() else { return }
            model.isApplying = true
            view.textStorage?.setAttributedString(VocabularyRichTextCodec.attributed(blocks, images: images))
            model.document = blocks; model.isApplying = false
        }
        // Loading pixels must not rebuild the document or reset its current selection.
        view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.string.utf16.count)) { value, _, _ in
            guard let attachment = value as? VocabularyRichTextAttachment, !attachment.pixelsLoaded,
                  let image = images[attachment.reference.filename] else { return }
            let display = VocabularyRichTextAttachment(id: attachment.contentID, reference: attachment.reference, caption: attachment.caption, image: image)
            attachment.attachmentCell = display.attachmentCell
            attachment.fileWrapper = display.fileWrapper; attachment.contents = display.contents
            attachment.pixelsLoaded = true
            view.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: view.string.utf16.count), actualCharacterRange: nil)
        }
        view.needsDisplay = true
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: VocabularyRichTextEditorModel
        init(model: VocabularyRichTextEditorModel) { self.model = model }
        func textDidChange(_ notification: Notification) { model.changed() }
        func textDidEndEditing(_ notification: Notification) { model.changed() }
        func textViewDidChangeSelection(_ notification: Notification) { model.selectionChanged() }
    }
}
