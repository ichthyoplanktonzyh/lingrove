import Foundation

/// User-authored explanation belongs to a stable sense, independently of AI records for a
/// particular usage. Blocks retain identity when reordered; files are referenced, never embedded
/// in the metadata. Optional sense storage preserves absent versus explicitly empty content.
nonisolated struct VocabularyContentBlock: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var content: Content

    enum Content: Codable, Equatable, Sendable {
        case text(VocabularyTextContent)
        case image(VocabularyImageReference, caption: String)
    }
}

/// Small, explicit formatting is shared by native reading and Anki serialization. User text
/// never becomes raw HTML. The editor changes these values without starting a model request.
nonisolated struct VocabularyTextContent: Codable, Equatable, Sendable {
    enum Style: String, Codable, CaseIterable, Sendable { case paragraph, heading, bullet }
    var text = ""
    var style: Style = .paragraph
    var bold = false
    var italic = false
}

/// Immutable PNG identity is its content hash. Dimensions bound decoding, and the byte count
/// bounds backup/media work before reading. A caption belongs to a block, not the shared image.
nonisolated struct VocabularyImageReference: Codable, Equatable, Hashable, Sendable {
    let digest: String
    let width: Int
    let height: Int
    let byteCount: Int
    var filename: String { "lg-image-" + digest + ".png" }
}

/// Imported bytes live only in an editor draft until Save. The archive writes referenced
/// images before committing the notebook; Cancel therefore has no disk resources to clean up.
nonisolated struct VocabularyPreparedImage: Sendable {
    let reference: VocabularyImageReference
    let data: Data
}

/// A portable, versioned single-file backup includes exactly the referenced media. Base64 is
/// the JSON transport, not the live storage format; regular notebook writes remain small.
nonisolated struct VocabularyBackup: Codable, Sendable {
    var version = 1
    let document: VocabularyDocument
    let images: [String: Data]
}
