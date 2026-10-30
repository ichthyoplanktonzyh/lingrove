import Foundation

/// A source occurrence stores UTF-16 coordinates, the same units used by saved
/// NSRange values and Accessibility on the Mac. Carrying them as plain values
/// preserves highlights across devices; string-boundary validation stays with
/// the notebook rules that also have the corresponding source text.
public nonisolated struct VocabularyTextRange: Codable, Equatable, Hashable, Sendable {
    public let location: Int
    public let length: Int

    public init(_ range: NSRange) {
        location = range.location
        length = range.length
    }

    public var nsRange: NSRange { NSRange(location: location, length: length) }
}
