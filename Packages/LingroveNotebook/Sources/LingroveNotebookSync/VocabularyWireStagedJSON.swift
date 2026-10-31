import Foundation

/// Staged bodies keep their original bytes across restarts. Foundation's keyed
/// decoder can collapse duplicate JSON keys, so the raw boundary needs its own
/// small scanner before a request is trusted. String decoding is still delegated
/// to Foundation; this helper owns duplicate/scalar/depth and numeric grammar.
nonisolated enum VocabularyWireStagedJSON {
    static func read(_ body: Data) throws -> VocabularyWireJSON {
        guard body.count <= VocabularyWireStagedLimits.maximumBodyBytes, String(data: body, encoding: .utf8) != nil else {
            throw VocabularyWireStagedError.invalidEnvelope
        }
        var reader = Reader(body: body, position: body.startIndex)
        let value = try reader.value(depth: 0); reader.whitespace()
        guard reader.position == body.endIndex else { throw VocabularyWireStagedError.invalidEnvelope }; return value
    }

    /// Owned only for one synchronous parse; Data uses copy-on-write storage.
    /// No references, tasks or mutable decoder state escape this operation.
    private struct Reader {
        let body: Data
        var position: Int
        mutating func whitespace() { while let byte = current, [9, 10, 13, 32].contains(byte) { position += 1 } }
        var current: UInt8? { position < body.endIndex ? body[position] : nil }
        mutating func require(_ byte: UInt8) throws {
            guard current == byte else { throw VocabularyWireStagedError.invalidEnvelope }; position += 1
        }
        mutating func codeUnit() throws -> Int {
            var result = 0
            for _ in 0..<4 {
                guard let byte = current else { throw VocabularyWireStagedError.invalidEnvelope }
                let value: Int
                switch byte { case 48...57: value = Int(byte - 48); case 65...70: value = Int(byte - 65 + 10); case 97...102: value = Int(byte - 97 + 10)
                default: throw VocabularyWireStagedError.invalidEnvelope }
                result = result * 16 + value; position += 1
            }
            return result
        }
        mutating func string() throws -> String {
            let start = position; try require(34)
            while let byte = current {
                position += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: body.subdata(in: start..<position)) }
                guard byte >= 32 else { throw VocabularyWireStagedError.invalidEnvelope }
                if byte == 92 {
                    guard let escaped = current else { throw VocabularyWireStagedError.invalidEnvelope }; position += 1
                    if escaped == 117 {
                        let unit = try codeUnit()
                        if (0xd800...0xdbff).contains(unit) {
                            try require(92); try require(117)
                            guard (0xdc00...0xdfff).contains(try codeUnit()) else { throw VocabularyWireStagedError.invalidEnvelope }
                        } else if (0xdc00...0xdfff).contains(unit) { throw VocabularyWireStagedError.invalidEnvelope }
                    } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) { throw VocabularyWireStagedError.invalidEnvelope }
                }
            }
            throw VocabularyWireStagedError.invalidEnvelope
        }
        mutating func value(depth: Int) throws -> VocabularyWireJSON {
            guard depth <= 32 else { throw VocabularyWireStagedError.invalidEnvelope }; whitespace()
            switch current {
            case 34: return .string(try string())
            case 123:
                position += 1; whitespace(); var values: [String: VocabularyWireJSON] = [:]; var keys = Set<Data>()
                if current == 125 { position += 1; return .object(values) }
                while true {
                    let key = try string(); whitespace(); try require(58)
                    // JSON equality is byte-exact after unescaping. Also refuse
                    // a Swift canonical-equivalence collision rather than let a
                    // dictionary silently reinterpret two distinct wire keys.
                    guard keys.insert(Data(key.utf8)).inserted, values[key] == nil else { throw VocabularyWireStagedError.invalidEnvelope }
                    values[key] = try value(depth: depth + 1); whitespace()
                    if current == 125 { position += 1; return .object(values) }
                    try require(44); whitespace()
                }
            case 91:
                position += 1; whitespace(); var values: [VocabularyWireJSON] = []
                if current == 93 { position += 1; return .array(values) }
                while true {
                    values.append(try value(depth: depth + 1)); whitespace()
                    if current == 93 { position += 1; return .array(values) }; try require(44)
                }
            case 116: try literal([116, 114, 117, 101]); return .bool(true)
            case 102: try literal([102, 97, 108, 115, 101]); return .bool(false)
            case 110: try literal([110, 117, 108, 108]); return .null
            default: return try number()
            }
        }
        mutating func literal(_ bytes: [UInt8]) throws { for byte in bytes { try require(byte) } }
        mutating func digits(required: Bool) throws {
            let start = position
            while let byte = current, (48...57).contains(byte) { position += 1 }
            if required, start == position { throw VocabularyWireStagedError.invalidEnvelope }
        }
        mutating func number() throws -> VocabularyWireJSON {
            let start = position
            if current == 45 { position += 1 }
            if current == 48 { position += 1 }
            else {
                guard let byte = current, (49...57).contains(byte) else { throw VocabularyWireStagedError.invalidEnvelope }
                try digits(required: true)
            }
            if current == 46 { position += 1; try digits(required: true) }
            if current == 101 || current == 69 {
                position += 1; if current == 43 || current == 45 { position += 1 }; try digits(required: true)
            }
            guard let text = String(data: body.subdata(in: start..<position), encoding: .ascii), let value = Double(text), value.isFinite else {
                throw VocabularyWireStagedError.invalidEnvelope
            }
            return .number(value)
        }
    }
}
