import Foundation

/// Paragraphs and media references form one sense explanation; a draft owns copies until Save.
/// These internal identities support persistence and references without exposing separate
/// editing fields. The shared value contains no window, decoder or model-runtime ownership.
public nonisolated struct VocabularyContentBlock: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var content: Content

    public init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }

    /// Images are references to archive-owned bytes. Their caption belongs to
    /// the block, so two uses of the same image can retain different captions.
    public enum Content: Codable, Hashable, Sendable {
        case text(VocabularyTextContent)
        case image(VocabularyImageReference, caption: String)
    }
}

/// Plain text and a small formatting vocabulary serve native views and export.
/// User text remains data rather than HTML, and editing a copy starts no model
/// request. Both platforms persist these same fields under the existing keys.
public nonisolated struct VocabularyTextContent: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable { case paragraph, heading, bullet }
    public var text: String
    public var style: Style
    public var bold: Bool
    public var italic: Bool
    /// Inline marks use UTF-16 offsets, matching native selections without storing platform fonts.
    public var runs: [VocabularyTextRun]?

    public init(text: String = "", style: Style = .paragraph, bold: Bool = false, italic: Bool = false, runs: [VocabularyTextRun]? = nil) {
        self.text = text
        self.style = style
        self.bold = bold
        self.italic = italic
        self.runs = runs
    }
}

/// One inline formatting range belongs to a text value. Identity and source language remain
/// on the sense; these marks describe presentation only and never split a learning unit.
public nonisolated struct VocabularyTextRun: Codable, Hashable, Sendable {
    public var location: Int
    public var length: Int
    public var bold: Bool
    public var italic: Bool
    public init(location: Int, length: Int, bold: Bool = false, italic: Bool = false) {
        self.location = location; self.length = length; self.bold = bold; self.italic = italic
    }
}

extension VocabularyTextContent {
    /// Readers and exporters share this normalized view. Paragraph-wide marks are a base;
    /// inline marks add emphasis without duplicating text or retaining native attributes.
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let bold: Bool
        public let italic: Bool
    }
    public var segments: [Segment] {
        let source = text as NSString
        var result: [Segment] = [], cursor = 0
        for run in runs ?? [] {
            guard run.location >= cursor, run.length > 0, run.location <= source.length,
                  run.length <= source.length - run.location else { continue }
            if run.location > cursor {
                result.append(.init(text: source.substring(with: NSRange(location: cursor, length: run.location - cursor)), bold: bold, italic: italic))
            }
            result.append(.init(text: source.substring(with: NSRange(location: run.location, length: run.length)),
                bold: bold || run.bold, italic: italic || run.italic))
            cursor = run.location + run.length
        }
        if cursor < source.length { result.append(.init(text: source.substring(from: cursor), bold: bold, italic: italic)) }
        return result
    }
}

/// An immutable PNG identity survives process and platform changes. The archive
/// validates and owns the bytes; views borrow this hash and its decoding bounds.
/// The filename policy is unchanged so existing local media stays addressable.
public nonisolated struct VocabularyImageReference: Codable, Hashable, Sendable {
    public let digest: String
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public var filename: String { "lg-image-" + digest + ".png" }

    public init(digest: String, width: Int, height: Int, byteCount: Int) {
        self.digest = digest
        self.width = width
        self.height = height
        self.byteCount = byteCount
    }
}

/// An editor owns imported bytes only for its draft lifetime. Saving passes the
/// reference and bytes together to the archive transaction; cancelling releases
/// this value without creating resources. It has no platform image object.
public nonisolated struct VocabularyPreparedImage: Sendable {
    public let reference: VocabularyImageReference
    public let data: Data

    public init(reference: VocabularyImageReference, data: Data) {
        self.reference = reference
        self.data = data
    }
}

/// A portable, versioned single-file backup includes exactly the referenced media. Base64 is
/// the JSON transport, not the live storage format; regular notebook writes remain small.
public nonisolated struct VocabularyBackup: Codable, Sendable {
    public var version = 1
    public let document: VocabularyDocument
    public let images: [String: Data]

    public init(
        version: Int = 1,
        document: VocabularyDocument,
        images: [String: Data]
    ) {
        self.version = version
        self.document = document
        self.images = images
    }
}
