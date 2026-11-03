import Foundation

/// Collections and review layouts own ordered blocks; an editor holds value
/// copies until Save.
/// This shared representation keeps identity and the existing Codable shape
/// independent of a window, mobile screen, image decoder or model runtime.
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

    public init(text: String = "", style: Style = .paragraph, bold: Bool = false, italic: Bool = false) {
        self.text = text
        self.style = style
        self.bold = bold
        self.italic = italic
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
