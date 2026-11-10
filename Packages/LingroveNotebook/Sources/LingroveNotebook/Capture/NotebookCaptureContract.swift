import Foundation

/// Validates the same capture material for the Mac CLI and the mobile notebook tool.
public nonisolated enum NotebookCaptureContract {
    public typealias Shape = NotebookToolShape.Shape
    private typealias Field = NotebookToolShape.Field
    private static let status = Field.enumeration(["confirmed", "proposed"])
    private static let sourceKind = Field.enumeration(["unspecified", "captured", "authored", "generated", "imported"])
    private static let label = Shape(fields: ["text": .text(4_096), "language": .text(100)], required: ["text"])
    private static let defaults = Shape(fields: ["language": .text(100), "meaningLanguage": .text(100),
        "translationLanguage": .text(100), "sourceKind": sourceKind, "status": status, "source": .text(4_096)])
    private static let meaning = Shape(fields: ["ref": .text(200), "id": .uuid, "title": .text(4_096),
        "language": .text(100), "kind": .enumeration(["concept", "function"]), "aliases": .array(.object(label), 63),
        "definition": .text(16_384), "cues": .array(.text(4_096), 64), "status": status,
        "categories": .array(.text(200), 64)], required: ["ref"])
    public static let example = Shape(fields: ["text": .text(262_144), "translation": .text(262_144),
        "translationLanguage": .text(100),
        "completeness": .enumeration(["sentence", "fragment", "unknown"]), "sourceKind": sourceKind,
        "sourceID": .uuid, "source": .text(4_096),
        "ranges": .array(.object(Shape(fields: ["location": .integer, "length": .integer], required: ["location", "length"])), 64)], required: ["text"])
    private static let association = Shape(fields: ["meaning": .text(200),
        "conditions": .text(8_192), "status": status], required: ["meaning"])
    public static var exampleEdit: Shape {
        var fields = example.fields
        fields.removeValue(forKey: "sourceID")
        fields["id"] = .uuid
        return .init(fields: fields, required: ["id"])
    }
    private static let sense = Shape(fields: ["id": .uuid, "meaning": .text(32_000), "meaningLanguage": .text(100),
        "explanation": .text(262_144), "note": .text(262_144), "tags": .array(.text(200), 100), "examples": .array(.object(example), 100),
        "associations": .array(.object(association), 64)])
    private static let entry = Shape(fields: ["expression": .text(32_000), "language": .text(100),
        "kind": .enumeration(["word", "expression", "pattern", "sentence"]), "dictionaryForm": .text(32_000),
        "senses": .array(.object(sense), 100)], required: ["expression", "senses"])
    private static let relation = Shape(fields: ["from": .text(200), "to": .text(200),
        "kind": .enumeration(["narrower", "opposite", "related"]), "note": .text(8_192), "status": status],
        required: ["from", "to", "kind"])
    public static var shape: Shape {
        .init(fields: ["defaults": .object(defaults), "meanings": .array(.object(meaning), 100),
            "entries": .array(.object(entry), 100), "relations": .array(.object(relation), 200)], required: ["entries"])
    }
    public static func decodeMaterial(_ data: Data) throws -> NotebookCaptureTask {
        let material = try shape.normalized(JSONDecoder().decode(NotebookToolJSON.self, from: data))
        let task = try JSONDecoder().decode(NotebookCaptureTask.self, from: JSONEncoder().encode(material))
        try validate(task)
        return task
    }

    public static func validate(_ capture: NotebookCaptureTask) throws {
        _ = try shape.normalized(NotebookToolJSON.value(capture))
        guard !capture.entries.isEmpty, capture.entries.allSatisfy({ !$0.senses.isEmpty }),
              capture.entries.reduce(0, { $0 + $1.senses.count }) <= 100,
              capture.entries.flatMap(\.senses).reduce(0, { $0 + ($1.examples?.count ?? 0) }) <= 1_000 else {
            throw NotebookToolError.invalid("Capture requires entries and senses, at most 100 senses and 1000 examples.")
        }
    }
}
