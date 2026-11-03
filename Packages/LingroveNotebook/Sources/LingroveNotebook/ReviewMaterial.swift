import CryptoKit
import Foundation

/// A target-neutral recipe belongs to a saved exercise, independently of scheduling and Anki.
/// Editors copy it until Save. Stable layout references follow the original sense; custom blocks
/// and generated audio remain owned material. Neither a remote deck nor a tool receipt belongs here.
public nonisolated struct ReviewMaterialPlan: Codable, Hashable, Sendable {
    public var name: String?
    public var layout: ReviewLayout
    public var exampleID: UUID?
    public var audio: [ReviewAudioKind: ReviewMaterialAudio]

    public init(name: String? = nil, layout: ReviewLayout, exampleID: UUID? = nil,
                audio: [ReviewAudioKind: ReviewMaterialAudio] = [:]) {
        self.name = name; self.layout = layout; self.exampleID = exampleID; self.audio = audio
    }
}

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

/// Audio stays typed through resolution. Its source hash prevents an old recording from silently
/// speaking new source text after refresh; fingerprint identifies the user's chosen voice/settings.
public nonisolated struct ReviewMaterialAudio: Codable, Hashable, Sendable {
    public let reference: ReviewMaterialMediaReference
    public let textHash: String
    public let fingerprint: String
    public init(reference: ReviewMaterialMediaReference, textHash: String, fingerprint: String) {
        self.reference = reference; self.textHash = textHash; self.fingerprint = fingerprint
    }
    public static func textHash(_ text: String) -> String { ReviewMaterialMediaReference.digest(Data(text.utf8)) }
}

/// Ordered resolved parts are portable data. Each renderer chooses native content or safe HTML;
/// user text never doubles as a media placeholder, and resolution never opens a review tool.
public nonisolated enum ReviewResolvedPart: Equatable, Sendable {
    case text(String), blocks([VocabularyContentBlock]), audio(ReviewAudioKind)
}
public nonisolated struct ReviewMaterialContent: Equatable, Sendable {
    public let front: [ReviewResolvedPart]
    public let back: [ReviewResolvedPart]
    public init(front: [ReviewResolvedPart], back: [ReviewResolvedPart]) { self.front = front; self.back = back }
}

/// Hosts localize these finite failures for their own preparation surface. Missing evidence is
/// distinct from malformed saved data, so a retained exercise can stay readable without guessing.
public nonisolated enum ReviewMaterialError: Error, Equatable, Sendable {
    case missingContent(ReviewContentSource), emptyFace, missingAudio(ReviewAudioKind)
}
