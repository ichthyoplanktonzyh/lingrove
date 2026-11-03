import Foundation

/// Editor merges compare durable bytes, including an authored NFC/NFD spelling choice. Swift's
/// String equality intentionally folds canonical normalization. This helper examines only the
/// small edited subtree; it never fingerprints the corpus or authorizes a database write.
nonisolated enum VocabularySaveLiteralEquality {
    static func equal<Value: Encodable>(_ lhs: Value, _ rhs: Value) throws -> Bool {
        try bytes(lhs) == bytes(rhs)
    }

    private static func bytes<Value: Encodable>(_ value: Value) throws -> Data {
        let data = try JSONEncoder().encode(value)
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: ordered(json), options: [.sortedKeys, .fragmentsAllowed])
    }

    /// Codable uses unordered arrays for Set and enum-keyed Dictionary fields. Sort only those
    /// existing model fields; the order of senses/examples/layouts/ordinary arrays remains data.
    /// JSONSerialization preserves literal strings while giving dictionaries a stable key order.
    private static func ordered(_ value: Any, field: String? = nil) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, element in
                result[element.key] = ordered(element.value, field: element.key)
            }
        }
        guard let array = value as? [Any] else { return value }
        if field == "audioKinds", let strings = array as? [String] { return strings.sorted() }
        if field == "audioReceipts" || field == "mapping", array.count.isMultiple(of: 2) {
            let pairs = stride(from: 0, to: array.count, by: 2).map { [ordered(array[$0]), ordered(array[$0 + 1])] }
            return pairs.sorted { String(describing: $0[0]) < String(describing: $1[0]) }.flatMap { $0 }
        }
        return array.map { ordered($0) }
    }
}
