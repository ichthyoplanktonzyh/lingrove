import CryptoKit
import Foundation

/// Stable identity is shared by capture reconciliation and SQLite's unique
/// lookup key. Normalization, UTF-8 length framing and SHA-256 are persisted
/// behavior; the storage adapter must never invent its own equivalent key.
public nonisolated enum VocabularyIdentityPolicy {
    private static let hexadecimal = Array("0123456789abcdef".utf8)
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func entryKey(expression: String, language: LearningLanguage?, kind: VocabularyEntry.Kind) -> String {
        key([language?.rawValue ?? "und", kind.rawValue, normalized(expression)])
    }

    public static func entryKey(_ entry: VocabularyEntry) -> String {
        entryKey(expression: entry.expression, language: entry.language, kind: entry.kind)
    }

    public static func exampleKey(_ example: VocabularyExample?) -> String {
        guard let example else { return "no-context" }
        // Preserve the legacy key, including classification, so existing deliberately distinct
        // examples remain valid. Sense reconciliation separately handles a unique unknown-state
        // observation. Annotation/translation languages are mutable content, not identity.
        return key([example.text, example.ranges.map { "\($0.location):\($0.length)" }.joined(separator: ","),
            example.completeness.rawValue])
    }

    private static func key(_ parts: [String]) -> String {
        // Length framing prevents strings containing delimiters from aliasing another capture.
        let value = parts.map { "\($0.utf8.count):\($0)" }.joined()
        // These exact lowercase ASCII bytes are persisted identity. Avoid Foundation's
        // variadic formatter once per digest byte when validating a large saved corpus.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(value.utf8)) {
            bytes.append(hexadecimal[Int(byte >> 4)])
            bytes.append(hexadecimal[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
