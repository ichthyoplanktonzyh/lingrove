import AppKit
import LingroveNotebook

/// Converts one draft explanation between portable content and the native text system.
/// The editor owns the attributed buffer; persistence still owns only text marks and media
/// references. Native fonts, attachment cells and selection state never enter the archive.
@MainActor
enum VocabularyRichTextCodec {
    static let blockKey = NSAttributedString.Key("LingroveContentID")
    static let styleKey = NSAttributedString.Key("LingroveParagraphStyle")
    static let bodyFont = NSFont.systemFont(ofSize: 14)

    static func font(bold: Bool, italic: Bool, heading: Bool = false) -> NSFont {
        var value = NSFont.systemFont(ofSize: heading ? 17 : 14, weight: heading || bold ? .bold : .regular)
        if italic { value = NSFontManager.shared.convert(value, toHaveTrait: .italicFontMask) }
        return value
    }

    static func attributed(_ blocks: [VocabularyContentBlock], images: [String: NSImage]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: defaults())) }
            let value: NSMutableAttributedString
            switch block.content {
            case let .text(text):
                value = NSMutableAttributedString(string: text.style == .bullet ? "• " : "", attributes: defaults())
                for segment in text.segments {
                    value.append(NSAttributedString(string: segment.text, attributes: [
                        .font: font(bold: segment.bold, italic: segment.italic, heading: text.style == .heading),
                        .foregroundColor: NSColor.labelColor
                    ]))
                }
                value.addAttribute(styleKey, value: text.style.rawValue, range: NSRange(location: 0, length: value.length))
            case let .image(reference, caption):
                let attachment = VocabularyRichTextAttachment(id: block.id, reference: reference, caption: caption,
                    image: images[reference.filename])
                value = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            }
            value.addAttribute(blockKey, value: block.id.uuidString, range: NSRange(location: 0, length: value.length))
            result.append(value)
        }
        return result
    }

    static func defaults(style: VocabularyTextContent.Style = .paragraph) -> [NSAttributedString.Key: Any] {
        [.font: font(bold: false, italic: false, heading: style == .heading), .foregroundColor: NSColor.labelColor,
         styleKey: style.rawValue]
    }

    /// Text and images retain their existing IDs when possible. A split paragraph gets a new
    /// identity, while changed wording never changes the owning sense or source evidence.
    static func blocks(_ value: NSAttributedString) -> [VocabularyContentBlock] {
        guard value.length > 0 else { return [] }
        let source = value.string as NSString
        var result: [VocabularyContentBlock] = [], seen = Set<UUID>(), cursor = 0
        func identity(at index: Int) -> UUID {
            let raw = index < value.length ? value.attribute(blockKey, at: index, effectiveRange: nil) as? String : nil
            let candidate = raw.flatMap(UUID.init(uuidString:)) ?? UUID()
            return seen.insert(candidate).inserted ? candidate : UUID()
        }
        func appendText(_ range: NSRange) {
            var range = range
            let rawStyle = range.location < value.length ? value.attribute(styleKey, at: range.location, effectiveRange: nil) as? String : nil
            var style = VocabularyTextContent.Style(rawValue: rawStyle ?? "") ?? .paragraph
            if style == .bullet {
                if source.substring(with: range).hasPrefix("• ") { range.location += 2; range.length -= 2 }
                else { style = .paragraph }
            }
            let text = source.substring(with: range)
            var runs: [VocabularyTextRun] = []
            value.enumerateAttribute(.font, in: range) { font, selection, _ in
                let traits = NSFontManager.shared.traits(of: (font as? NSFont) ?? bodyFont)
                let bold = traits.contains(.boldFontMask) && style != .heading
                let italic = traits.contains(.italicFontMask)
                if bold || italic {
                    runs.append(.init(location: selection.location - range.location, length: selection.length, bold: bold, italic: italic))
                }
            }
            result.append(.init(id: identity(at: range.location), content: .text(.init(text: text, style: style, runs: runs.isEmpty ? nil : runs))))
        }
        while cursor < source.length {
            let paragraph = source.paragraphRange(for: NSRange(location: cursor, length: 0))
            var end = NSMaxRange(paragraph)
            while end > cursor, [10, 13].contains(Int(source.character(at: end - 1))) { end -= 1 }
            var textStart = cursor
            if cursor == end { appendText(NSRange(location: cursor, length: 0)) }
            for index in cursor..<end {
                guard let attachment = value.attribute(.attachment, at: index, effectiveRange: nil) as? VocabularyRichTextAttachment else { continue }
                if index > textStart { appendText(NSRange(location: textStart, length: index - textStart)) }
                let id = seen.insert(attachment.contentID).inserted ? attachment.contentID : UUID()
                result.append(.init(id: id, content: .image(attachment.reference, caption: attachment.caption)))
                textStart = index + 1
            }
            if textStart < end { appendText(NSRange(location: textStart, length: end - textStart)) }
            cursor = NSMaxRange(paragraph)
        }
        if value.string.hasSuffix("\n") { result.append(.init(content: .text(.init()))) }
        return result
    }
}

/// A native attachment borrows a validated image reference and temporary display pixels.
/// Keeping its caption with the attachment preserves it through movement, deletion and undo.
@MainActor
final class VocabularyRichTextAttachment: NSTextAttachment {
    let contentID: UUID
    let reference: VocabularyImageReference
    var caption: String
    var pixelsLoaded: Bool

    init(id: UUID, reference: VocabularyImageReference, caption: String, image: NSImage?) {
        contentID = id; self.reference = reference; self.caption = caption; pixelsLoaded = image != nil
        let bytes = image?.tiffRepresentation
        super.init(data: bytes, ofType: bytes == nil ? nil : "public.tiff")
        if let bytes {
            fileWrapper = FileWrapper(regularFileWithContents: bytes)
            fileWrapper?.preferredFilename = reference.digest + ".tiff"
        }
        if let image {
            let copy = NSImage(size: image.size)
            copy.addRepresentations(image.representations)
            let scale = min(1, 480 / max(1, copy.size.width), 240 / max(1, copy.size.height))
            copy.size = NSSize(width: copy.size.width * scale, height: copy.size.height * scale)
            attachmentCell = NSTextAttachmentCell(imageCell: copy)
        } else {
            attachmentCell = NSTextAttachmentCell(textCell: String(localized: "Image unavailable", table: "Vocabulary"))
        }
    }
    required init?(coder: NSCoder) { return nil }
}
