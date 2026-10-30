import Foundation

/// Pure content rules are shared by archive validation, editing and review. No file access or
/// model work occurs here; both notebook and Anki use the same meaningful-content definition.
public nonisolated enum VocabularyContentPolicy {
    public static let maximumImageBytes = 4 * 1_024 * 1_024
    public static let maximumSenseImageBytes = 16 * 1_024 * 1_024
    public static let maximumDimension = 1_600

    public static func images(_ blocks: [VocabularyContentBlock]) -> [VocabularyImageReference] {
        blocks.compactMap { if case let .image(image, _) = $0.content { image } else { nil } }
    }

    public static func meaningful(_ blocks: [VocabularyContentBlock]) -> Bool {
        blocks.contains {
            switch $0.content {
            case let .text(value): !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image: true
            }
        }
    }

    public static func valid(_ image: VocabularyImageReference) -> Bool {
        image.digest.count == 64 && image.digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            (1...maximumDimension).contains(image.width) && (1...maximumDimension).contains(image.height) &&
            (1...maximumImageBytes).contains(image.byteCount)
    }

    public static func validate(_ blocks: [VocabularyContentBlock]) throws {
        guard blocks.count <= 64, Set(blocks.map(\.id)).count == blocks.count else {
            throw VocabularyError.invalidContent
        }
        for block in blocks {
            switch block.content {
            case let .text(value):
                guard value.text.utf8.count <= 262_144 else { throw VocabularyError.invalidContent }
            case let .image(image, caption):
                guard valid(image), caption.utf8.count <= 16_384 else { throw VocabularyError.invalidContent }
            }
        }
        // Validate each count before summing: imported JSON may contain Int.max, which must
        // produce a recoverable validation error rather than an integer-overflow trap.
        guard images(blocks).reduce(0, { $0 + $1.byteCount }) <= maximumSenseImageBytes else {
            throw VocabularyError.invalidContent
        }
    }


}
