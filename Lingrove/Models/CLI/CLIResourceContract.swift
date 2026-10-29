import Foundation

/// The app and bundled executable share one closed resource vocabulary. Shape validation and
/// published JSON Schema come from these same descriptors, so misspelled nested fields cannot
/// silently disappear through Codable. Domain references remain the archive's responsibility.
nonisolated enum CLIResourceContract {
    /// A descriptor recursively checks one wire value and emits the equivalent schema. These
    /// immutable values live in the shared contract, without depending on app domain types.
    indirect enum Field: Sendable {
        case text(Int), uuid, date, bool, integer, confidence, enumeration([String]), object(Shape), array(Field, Int), nullable(Field)

        // Each case validates one wire type; none shares mutable state with another case.
        // swiftlint:disable:next cyclomatic_complexity
        func normalized(_ value: CLIJSON) throws -> CLIJSON {
            switch (self, value) {
            case let (.text(limit), .string(text)) where text.utf8.count <= limit: return value
            case let (.uuid, .string(text)) where UUID(uuidString: text) != nil: return value
            case let (.date, .number(number)) where number.isFinite: return value
            case (.date, .integer): return value
            case (.bool, .bool): return value
            case let (.integer, .integer(number)) where number >= 0: return value
            case let (.confidence, .number(number)) where number.isFinite && (0...1).contains(number): return value
            case let (.confidence, .integer(number)) where (0...1).contains(number): return value
            case let (.enumeration(allowed), .string(text)) where allowed.contains(text): return value
            case let (.object(shape), _): return try shape.normalized(value)
            case let (.array(field, limit), .array(values)) where values.count <= limit:
                return .array(try values.map { try field.normalized($0) })
            case (.nullable, .null): return value
            case let (.nullable(field), _): return try field.normalized(value)
            default: throw CLIError.invalid("Invalid resource field type, enum or size. Run 'lingrove schema'.")
            }
        }

        var schema: [String: Any] {
            switch self {
            case let .text(limit): ["type": "string", "maxLength": limit]
            case .uuid: ["type": "string", "format": "uuid"]
            case .date: ["type": "number", "description": "Unix seconds since 1970-01-01 UTC"]
            case .bool: ["type": "boolean"]
            case .integer: ["type": "integer", "minimum": 0]
            case .confidence: ["type": "number", "minimum": 0, "maximum": 1]
            case let .enumeration(values): ["enum": values]
            case let .object(shape): shape.schema
            case let .array(field, limit): ["type": "array", "maxItems": limit, "items": field.schema]
            case let .nullable(field): ["anyOf": [field.schema, ["type": "null"]]]
            }
        }
    }

    /// Closed fields, creation requirements and defaults for one object. Root patches retain
    /// omitted fields; replacement array elements use complete independently validated shapes.
    struct Shape: Sendable {
        let fields: [String: Field]
        var required: Set<String> = []
        var defaults: [String: CLIJSON] = [:]

        func normalized(_ input: CLIJSON, creating: Bool = true) throws -> CLIJSON {
            guard case let .object(value) = input, Set(value.keys).isSubset(of: Set(fields.keys)),
                  !creating || required.isSubset(of: Set(value.keys)) else {
                throw CLIError.invalid("Unknown or missing resource fields. Run 'lingrove schema'.")
            }
            var result = creating ? defaults : [:]
            for (key, value) in value {
                guard let field = fields[key] else { throw CLIError.invalid("Unknown resource field.") }
                result[key] = try field.normalized(value)
            }
            return .object(result)
        }
        var schema: [String: Any] {
            ["type": "object", "additionalProperties": false,
             "properties": fields.mapValues(\.schema), "required": Array(required).sorted()]
        }
    }

    static let names = ["entries", "senses", "sources", "occurrences", "interpretations", "collections",
                        "nodes", "patterns", "mappings", "relations", "cues", "cueTargets",
                        "frameworks", "categories", "categoryParents", "categoryMemberships", "categoryOverrides"]
    static let provenance = Shape(fields: ["origin": .enumeration(["user", "imported", "model"]),
        "status": .enumeration(["confirmed", "proposed"]), "source": .text(4_096), "confidence": .nullable(.confidence)])
    static let range = Shape(fields: ["location": .integer, "length": .integer], required: ["location", "length"])
    static let meaning = Shape(fields: ["text": .text(262_144), "language": .nullable(.text(100))], required: ["text"])
    static let label = Shape(fields: ["id": .uuid, "text": .text(4_096), "language": .nullable(.text(100)), "preferred": .bool],
        required: ["id", "text"], defaults: ["preferred": .bool(true)])
    static let role = Shape(fields: ["id": .uuid, "name": .text(200), "description": .text(4_096)],
        required: ["id", "name"], defaults: ["description": .string("")])
    static let slot = Shape(fields: ["id": .uuid, "name": .text(200), "constraint": .text(4_096)],
        required: ["id", "name"], defaults: ["constraint": .string("")])
    static let binding = Shape(fields: ["id": .uuid, "roleID": .uuid, "slotID": .uuid], required: ["id", "roleID", "slotID"])

    // Each root descriptor permits partial updates; required fields describe creation. UUIDs
    // inside replacement arrays are explicit too, making an agent's retry structurally stable.
    // Closed dispatch keeps every supported resource discoverable in one place.
    // swiftlint:disable:next cyclomatic_complexity
    static func shape(_ resource: String) throws -> Shape {
        switch resource {
        case "frameworks":
            return .init(fields: ["id": .uuid, "key": .text(200), "version": .integer], required: ["id", "key", "version"])
        case "categories":
            return .init(fields: ["id": .uuid, "axis": .enumeration(["content", "function"]),
                "labels": .array(.object(label), 64), "definition": .text(16_384), "frameworkID": .nullable(.uuid),
                "key": .nullable(.text(200)), "isRetired": .bool, "provenance": .object(provenance)],
                required: ["id", "axis", "labels"])
        case "categoryParents":
            return .init(fields: ["id": .uuid, "categoryID": .uuid, "parentID": .uuid], required: ["id", "categoryID", "parentID"])
        case "categoryMemberships":
            return .init(fields: ["id": .uuid, "nodeID": .uuid, "categoryID": .uuid, "provenance": .object(provenance)],
                required: ["id", "nodeID", "categoryID"])
        case "categoryOverrides":
            return .init(fields: ["categoryID": .uuid, "labels": .nullable(.array(.object(label), 64)),
                "definition": .nullable(.text(16_384)), "isHidden": .bool], required: ["categoryID"])
        case "entries":
            return .init(fields: ["id": .uuid, "expression": .text(32_000), "dictionaryForm": .text(32_000),
                "language": .nullable(.text(100)), "kind": .enumeration(["word", "expression", "pattern", "sentence"]),
                "createdAt": .date, "updatedAt": .date], required: ["id", "expression", "kind"])
        case "senses":
            return .init(fields: ["id": .uuid, "entryID": .uuid, "meaning": .text(32_000), "meaningLanguage": .nullable(.text(100)),
                "meaningOrigin": .enumeration(["captured", "ai", "user"]),
                "alternateMeanings": .array(.object(meaning), 64), "mergedFrom": .array(.uuid, 128),
                "createdWithoutContext": .nullable(.bool),
                "createdAt": .date, "updatedAt": .date], required: ["id", "entryID", "meaning"])
        case "sources":
            return .init(fields: ["id": .uuid, "text": .text(262_144),
                "kind": .enumeration(["unspecified", "captured", "authored", "generated", "imported"]),
                "appBundleIdentifier": .nullable(.text(1_024)), "encounteredAt": .date], required: ["id", "text", "kind"])
        case "occurrences":
            return .init(fields: ["id": .uuid, "sourceID": .uuid, "ranges": .array(.object(range), 64)],
                required: ["id", "sourceID", "ranges"])
        case "interpretations":
            return .init(fields: ["id": .uuid, "occurrenceID": .uuid, "senseID": .nullable(.uuid),
                "status": .enumeration(["candidate", "accepted", "rejected"]), "meaning": .text(32_000),
                "meaningLanguage": .nullable(.text(100)), "meaningOrigin": .enumeration(["captured", "ai", "user"]),
                "translation": .text(262_144), "translationLanguage": .nullable(.text(100)),
                "translationVariants": .array(.object(meaning), 64),
                "completeness": .enumeration(["sentence", "fragment", "unknown"]),
                "provenance": .object(provenance), "createdAt": .date], required: ["id", "occurrenceID"])
        case "collections":
            return .init(fields: ["senseID": .uuid, "interpretationIDs": .array(.uuid, 10_000),
                "isSavedWithoutContext": .bool, "note": .text(262_144), "tags": .array(.text(200), 100), "savedAt": .date],
                required: ["senseID"])
        case "nodes":
            return .init(fields: ["id": .uuid, "kind": .enumeration(["concept", "function"]),
                "labels": .array(.object(label), 64), "definition": .text(16_384), "scopeNote": .text(16_384),
                "roles": .array(.object(role), 32), "provenance": .object(provenance), "createdAt": .date, "updatedAt": .date],
                required: ["id", "labels"])
        case "patterns":
            return .init(fields: ["id": .uuid, "senseID": .uuid, "template": .text(8_192), "slots": .array(.object(slot), 32),
                "formality": .enumeration(["unspecified", "informal", "neutral", "formal"]),
                "medium": .enumeration(["unspecified", "spoken", "written", "both"]), "region": .text(200), "note": .text(8_192),
                "collocations": .array(.text(1_024), 128), "provenance": .object(provenance)], required: ["id", "senseID", "template"])
        case "mappings":
            return .init(fields: ["id": .uuid, "nodeID": .uuid, "senseID": .uuid, "patternID": .nullable(.uuid),
                "relation": .enumeration(["expressesContent", "realizesFunction"]), "conditions": .text(8_192), "nuance": .text(8_192),
                "roleBindings": .array(.object(binding), 32), "evidenceIDs": .array(.uuid, 128), "provenance": .object(provenance)],
                required: ["id", "nodeID", "senseID"])
        case "relations":
            return .init(fields: ["id": .uuid, "sourceID": .uuid, "targetID": .uuid,
                "kind": .enumeration(["narrower", "opposite", "related"]), "note": .text(8_192), "provenance": .object(provenance)],
                required: ["id", "sourceID", "targetID"])
        case "cues":
            return .init(fields: ["id": .uuid, "text": .text(4_096), "language": .nullable(.text(100)),
                "kind": .enumeration(["paraphrase", "simpleExpression", "personal"])], required: ["id", "text"])
        case "cueTargets":
            return .init(fields: ["id": .uuid, "cueID": .uuid, "nodeID": .uuid, "conditions": .text(8_192),
                "provenance": .object(provenance)], required: ["id", "cueID", "nodeID"])
        default: throw CLIError.invalid("Unknown resource. Use: " + names.joined(separator: ", ") + ".")
        }
    }
}
