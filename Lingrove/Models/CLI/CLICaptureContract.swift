import Foundation

/// One closed task descriptor produces both validation and `schema capture`. Keeping schema
/// and parsing together prevents a misspelled association or default from being discarded by
/// Codable. This module depends only on wire values, so app and client use identical rules.
nonisolated enum CLICaptureContract {
    private typealias Shape = CLIResourceContract.Shape
    private typealias Field = CLIResourceContract.Field
    private static let status = Field.enumeration(["confirmed", "proposed"])
    private static let sourceKind = Field.enumeration(["unspecified", "captured", "authored", "generated", "imported"])
    private static let label = Shape(fields: ["text": .text(4_096), "language": .text(100)], required: ["text"])
    private static let defaults = Shape(fields: ["language": .text(100), "meaningLanguage": .text(100),
        "translationLanguage": .text(100), "sourceKind": sourceKind, "status": status, "source": .text(4_096)])
    private static let meaning = Shape(fields: ["ref": .text(200), "id": .uuid, "title": .text(4_096),
        "language": .text(100), "kind": .enumeration(["concept", "function"]), "aliases": .array(.object(label), 63),
        "definition": .text(16_384), "cues": .array(.text(4_096), 64), "status": status,
        "categories": .array(.text(200), 64)], required: ["ref"])
    private static let example = Shape(fields: ["text": .text(262_144), "translation": .text(262_144),
        "translationLanguage": .text(100), "meaning": .text(32_000), "meaningLanguage": .text(100),
        "completeness": .enumeration(["sentence", "fragment", "unknown"]), "sourceKind": sourceKind,
        "ranges": .array(.object(CLIResourceContract.range), 64)], required: ["text"])
    private static let association = Shape(fields: ["meaning": .text(200), "usage": .text(8_192),
        "nuance": .text(8_192), "conditions": .text(8_192), "formality": .enumeration(["unspecified", "informal", "neutral", "formal"]),
        "medium": .enumeration(["unspecified", "spoken", "written", "both"]), "collocations": .array(.text(1_024), 128),
        "status": status], required: ["meaning"])
    private static let sense = Shape(fields: ["id": .uuid, "meaning": .text(32_000), "meaningLanguage": .text(100),
        "note": .text(262_144), "tags": .array(.text(200), 100), "examples": .array(.object(example), 100),
        "associations": .array(.object(association), 64)])
    private static let entry = Shape(fields: ["expression": .text(32_000), "language": .text(100),
        "kind": .enumeration(["word", "expression", "pattern", "sentence"]), "dictionaryForm": .text(32_000),
        "senses": .array(.object(sense), 100)], required: ["expression", "senses"])
    private static let relation = Shape(fields: ["from": .text(200), "to": .text(200),
        "kind": .enumeration(["narrower", "opposite", "related"]), "note": .text(8_192), "status": status],
        required: ["from", "to", "kind"])
    static var shape: CLIResourceContract.Shape {
        .init(fields: ["defaults": .object(defaults), "meanings": .array(.object(meaning), 100),
            "entries": .array(.object(entry), 100), "relations": .array(.object(relation), 200)], required: ["entries"])
    }
    private static var document: Shape {
        // Header is separate from material so it cannot become stored learning data.
        .init(fields: shape.fields.merging(["version": .integer, "idempotencyKey": .text(200),
            "expectedRevision": .integer]) { _, new in new }, required: ["version", "idempotencyKey", "entries"])
    }

    static var schema: [String: Any] {
        var root = document.schema
        var properties = root["properties"] as? [String: Any] ?? [:]
        properties["version"] = ["const": 1]
        root["properties"] = properties
        root["title"] = "Lingrove capture task v1"
        root["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        return root
    }

    static func decode(_ data: Data) throws -> CLIBatch {
        guard data.count <= CLIInputPolicy.maximumBytes else { throw CLIError.invalid("Input exceeds 32 MiB.") }
        do {
            guard case var .object(fields) = try JSONDecoder().decode(CLIJSON.self, from: data),
                  case .integer(1)? = fields.removeValue(forKey: "version"),
                  case let .string(key)? = fields.removeValue(forKey: "idempotencyKey") else {
                throw CLIError.invalid("Capture needs version 1 and idempotencyKey. Run 'lingrove schema capture'.")
            }
            let revision: UInt64?
            if let supplied = fields.removeValue(forKey: "expectedRevision") {
                guard case let .integer(number) = supplied, number >= 0 else { throw CLIError.invalid("Invalid expectedRevision.") }
                revision = UInt64(number)
            } else { revision = nil }
            let material = try shape.normalized(.object(fields))
            let capture = try JSONDecoder().decode(CLICapture.self, from: JSONEncoder().encode(material))
            let batch = CLIBatch(version: 2, idempotencyKey: key, expectedRevision: revision, operations: [.init(capture: capture)])
            try CLIInputPolicy.validate(batch)
            return batch
        } catch let error as CLIError { throw error } catch {
            throw CLIError.invalid("Invalid capture JSON. Run 'lingrove schema capture'.")
        }
    }

    static func validate(_ capture: CLICapture) throws {
        _ = try shape.normalized(CLIJSON.value(capture))
        guard !capture.entries.isEmpty, capture.entries.allSatisfy({ !$0.senses.isEmpty }),
              capture.entries.reduce(0, { $0 + $1.senses.count }) <= 100,
              capture.entries.flatMap(\.senses).reduce(0, { $0 + ($1.examples?.count ?? 0) }) <= 1_000 else {
            throw CLIError.invalid("Capture requires entries and senses, at most 100 senses and 1000 examples.")
        }
    }
}
