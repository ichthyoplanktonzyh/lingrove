import Foundation

/// The two optional recordings belong to a review plan, independently of its source meaning.
public nonisolated enum ReviewAudioKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case expression, sentence
    public var id: String { rawValue }
    public var field: ReviewField { self == .expression ? .expressionAudio : .sentenceAudio }

}

/// A receipt names Anki-owned media and the exact text/voice settings that produced it. A
/// subsequent process can reuse a successful upload without persisting temporary audio locally.
public nonisolated struct ReviewAudioReceipt: Codable, Equatable, Sendable {
    public let fingerprint: String
    public let textHash: String
    public let endpoint: String
    public let profile: String
    public let filename: String

    public init(
        fingerprint: String,
        textHash: String,
        endpoint: String,
        profile: String,
        filename: String
    ) {
        self.fingerprint = fingerprint
        self.textHash = textHash
        self.endpoint = endpoint
        self.profile = profile
        self.filename = filename
    }
}
