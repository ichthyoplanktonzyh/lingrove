import Foundation
import LingroveNotebook

/// A field reader consumes known keys. Foundation's normal Codable decoding
/// ignores unknown keys; doing that at this seam could accept private remote
/// configuration or silently drop a future public field.
nonisolated struct VocabularyWireFields {
    typealias J = VocabularyWireJSON
    private var values: [String: J]
    init(_ values: [String: J]) { self.values = values }
    init(_ value: J) throws {
        guard case let .object(values) = value else { throw VocabularyWireError.invalidRecord }
        self.values = values
    }
    mutating func take(_ key: String) throws -> J {
        guard let value = values.removeValue(forKey: key) else { throw VocabularyWireError.invalidRecord }; return value
    }
    mutating func string(_ key: String) throws -> String {
        guard case let .string(value) = try take(key) else { throw VocabularyWireError.invalidRecord }; return value
    }
    mutating func bool(_ key: String) throws -> Bool {
        guard case let .bool(value) = try take(key) else { throw VocabularyWireError.invalidRecord }; return value
    }
    mutating func number(_ key: String) throws -> Double {
        guard case let .number(value) = try take(key), value.isFinite else { throw VocabularyWireError.invalidRecord }; return value
    }
    mutating func integer(_ key: String, maximum: Int = 2_147_483_647, minimum: Int = 0) throws -> Int {
        let value = try number(key)
        guard value >= Double(minimum), value <= Double(maximum), value.rounded(.towardZero) == value else { throw VocabularyWireError.invalidRecord }
        return Int(value)
    }
    mutating func date(_ key: String) throws -> Date { try Self.date(take(key)) }
    static func date(_ value: J) throws -> Date {
        guard case let .number(seconds) = value, seconds.isFinite else { throw VocabularyWireError.invalidRecord }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
    mutating func uuid(_ key: String) throws -> UUID { try Self.uuid(string(key)) }
    static func uuid(_ text: String) throws -> UUID {
        guard text == text.lowercased(), let id = UUID(uuidString: text), id.uuidString.lowercased() == text else { throw VocabularyWireError.invalidRecord }; return id
    }
    mutating func raw<T: RawRepresentable>(_ key: String, _ type: T.Type) throws -> T where T.RawValue == String {
        guard let result = T(rawValue: try string(key)) else { throw VocabularyWireError.invalidRecord }; return result
    }
    mutating func array(_ key: String) throws -> [J] {
        guard case let .array(values) = try take(key) else { throw VocabularyWireError.invalidRecord }; return values
    }
    mutating func optional<T>(_ key: String, _ transform: (J) throws -> T) throws -> T? {
        let value = try take(key); if value == .null { return nil }; return try transform(value)
    }
    mutating func optionalIfPresent<T>(_ key: String, _ transform: (J) throws -> T) throws -> T? {
        guard values[key] != nil else { return nil }
        return try optional(key, transform)
    }
    func finish() throws { guard values.isEmpty else { throw VocabularyWireError.invalidRecord } }

    static func string(_ value: J) throws -> String {
        guard case let .string(text) = value else { throw VocabularyWireError.invalidRecord }; return text
    }
    static func bool(_ value: J) throws -> Bool {
        guard case let .bool(flag) = value else { throw VocabularyWireError.invalidRecord }; return flag
    }
    static func array(_ value: J) throws -> [J] {
        guard case let .array(values) = value else { throw VocabularyWireError.invalidRecord }; return values
    }
    static func optionalLanguage(_ value: J) throws -> LearningLanguage {
        guard let language = LearningLanguage(rawValue: try string(value)) else { throw VocabularyWireError.invalidRecord }; return language
    }
}

/// Leaf reconstruction mirrors the explicit public shape, including nullable
/// choices. Private explanation context is restored only by the separate local overlay.
nonisolated enum VocabularyWireReading {
    typealias J = VocabularyWireJSON
    typealias F = VocabularyWireFields
    static func ranges(_ value: J) throws -> [VocabularyTextRange] {
        try F.array(value).map { row in
            var f = try F(row); let location = try f.integer("location"), length = try f.integer("length", minimum: 1)
            try f.finish(); return VocabularyTextRange(NSRange(location: location, length: length))
        }
    }
    static func meanings(_ value: J) throws -> [VocabularyMeaning] {
        try F.array(value).map { row in
            var f = try F(row); let result = VocabularyMeaning(text: try f.string("text"), language: try f.optional("language", F.optionalLanguage))
            try f.finish(); return result
        }
    }
    static func provenance(_ value: J) throws -> VocabularySemanticProvenance {
        var f = try F(value)
        let result = VocabularySemanticProvenance(origin: try f.raw("origin", VocabularySemanticProvenance.Origin.self),
            status: try f.raw("status", VocabularySemanticProvenance.Status.self), source: try f.string("source"), confidence: try f.optional("confidence") {
                guard case let .number(number) = $0, number.isFinite else { throw VocabularyWireError.invalidRecord }; return number
            })
        try f.finish(); return result
    }
    static func labels(_ value: J) throws -> [VocabularyMeaningLabel] {
        try F.array(value).map { row in
            var f = try F(row); let result = VocabularyMeaningLabel(id: try f.uuid("id"), text: try f.string("text"),
                language: try f.optional("language", F.optionalLanguage), preferred: try f.bool("preferred"))
            try f.finish(); return result
        }
    }
    static func content(_ value: J) throws -> VocabularyContentBlock.Content {
        var f = try F(value); let type = try f.string("type")
        let result: VocabularyContentBlock.Content
        switch type {
        case "text":
            result = .text(.init(text: try f.string("text"), style: try f.raw("style", VocabularyTextContent.Style.self), bold: try f.bool("bold"), italic: try f.bool("italic"), runs: try f.optionalIfPresent("runs") { value in
                try F.array(value).map { item in
                    var run = try F(item)
                    let result = VocabularyTextRun(location: try run.integer("location", minimum: 0), length: try run.integer("length", minimum: 1), bold: try run.bool("bold"), italic: try run.bool("italic"))
                    try run.finish(); return result
                }
            }))
        case "image":
            var image = try F(f.take("image")); let reference = VocabularyImageReference(digest: try image.string("digest"),
                width: try image.integer("width", minimum: 1), height: try image.integer("height", minimum: 1), byteCount: try image.integer("byteCount", minimum: 1))
            try image.finish(); result = .image(reference, caption: try f.string("caption"))
        default: throw VocabularyWireError.invalidRecord
        }
        try f.finish(); return result
    }
    static func block(_ value: J) throws -> VocabularyContentBlock {
        var f = try F(value); let result = VocabularyContentBlock(id: try f.uuid("id"), content: try content(f.take("content")))
        try f.finish(); return result
    }
    static func input(_ value: J) throws -> LearningExplanationInput {
        var f = try F(value); let result = LearningExplanationInput(target: try f.string("target"), dictionaryForm: try f.string("dictionaryForm"),
            language: try f.optional("language", F.optionalLanguage), kind: try f.raw("kind", VocabularyEntry.Kind.self), context: try f.string("context"),
            ranges: try ranges(f.take("ranges")), contextKind: try f.raw("contextKind", LearningExplanationContext.self))
        try f.finish(); return result
    }
    static func categoryExamples(_ value: J) throws -> [VocabularyCategoryExample] {
        try F.array(value).map { row in
            var f = try F(row); let result = VocabularyCategoryExample(text: try f.string("text"), language: try f.optional("language", F.string))
            try f.finish(); return result
        }
    }
    static func categoryReferences(_ value: J) throws -> [VocabularyCategoryReference] {
        try F.array(value).map { row in
            var f = try F(row); let result = VocabularyCategoryReference(source: try f.string("source"), identifier: try f.string("identifier"),
                url: try f.string("url"), relationship: try f.raw("relationship", VocabularyCategoryReference.Relationship.self),
                attribution: try f.optional("attribution", F.string), license: try f.optional("license", F.string))
            try f.finish(); return result
        }
    }
    static func localizations(_ value: J) throws -> [VocabularyCategoryLocalization] {
        try F.array(value).map { row in
            var f = try F(row); let result = VocabularyCategoryLocalization(language: try f.string("language"), name: try f.optional("name", F.string),
                definition: try f.optional("definition", F.string), scopeNote: try f.optional("scopeNote", F.string))
            try f.finish(); return result
        }
    }
}
