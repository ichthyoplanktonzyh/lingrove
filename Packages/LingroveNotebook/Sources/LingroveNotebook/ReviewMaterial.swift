import CryptoKit
import Foundation

/// Content addressing names portable bytes, never a local path or an Anki filename. Optional
/// dimensions are required for PNGs and forbidden for audio. The engine grants workspace access
/// only when the matching validated bytes are committed with an exercise.
public nonisolated struct ReviewMaterialMediaReference: Codable, Hashable, Sendable {
    public let digest: String
    public let mimeType: String
    public let byteCount: Int
    public let width: Int?
    public let height: Int?

    public init(digest: String, mimeType: String, byteCount: Int, width: Int? = nil, height: Int? = nil) {
        self.digest = digest; self.mimeType = mimeType; self.byteCount = byteCount
        self.width = width; self.height = height
    }
    public init(image: VocabularyImageReference) {
        self.init(digest: image.digest, mimeType: "image/png", byteCount: image.byteCount,
                  width: image.width, height: image.height)
    }
    public var image: VocabularyImageReference? {
        guard mimeType == "image/png", let width, let height else { return nil }
        return .init(digest: digest, width: width, height: height, byteCount: byteCount)
    }
    public static let maximumBytes = 4 * 1024 * 1024
    public var isValid: Bool {
        guard (1...Self.maximumBytes).contains(byteCount), digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        if mimeType == "image/png" { return image.map(VocabularyContentPolicy.valid) ?? false }
        return ["audio/wav", "audio/mpeg"].contains(mimeType) && width == nil && height == nil
    }
    public static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// A draft owns these bytes until its explicit save command. Constructing or cancelling this
/// value performs no IO; transactional storage validates both identity and media format.
public nonisolated struct ReviewMaterialPreparedMedia: Codable, Equatable, Sendable {
    public let reference: ReviewMaterialMediaReference
    public let data: Data
    public init(reference: ReviewMaterialMediaReference, data: Data) { self.reference = reference; self.data = data }
}
