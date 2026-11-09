import Foundation

public nonisolated enum NotebookToolShape {
    /// A descriptor recursively checks one wire value and emits the equivalent schema. These
    /// immutable values live in the shared contract, without depending on app domain types.
    public indirect enum Field: Sendable {
        case text(Int), uuid, date, bool, integer, confidence, enumeration([String]), object(Shape), array(Field, Int), nullable(Field)

        // Each case validates one wire type; none shares mutable state with another case.
        // swiftlint:disable:next cyclomatic_complexity
        public func normalized(_ value: NotebookToolJSON) throws -> NotebookToolJSON {
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
            default: throw NotebookToolError.invalid("Invalid resource field type, enum or size. Run 'lingrove schema'.")
            }
        }

        public var schema: [String: Any] {
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
    public struct Shape: Sendable {
        public let fields: [String: Field]
        public var required: Set<String> = []
        public var defaults: [String: NotebookToolJSON] = [:]

        public init(fields: [String: Field], required: Set<String> = [], defaults: [String: NotebookToolJSON] = [:]) {
            self.fields = fields
            self.required = required
            self.defaults = defaults
        }

        public func normalized(_ input: NotebookToolJSON, creating: Bool = true) throws -> NotebookToolJSON {
            guard case let .object(value) = input, Set(value.keys).isSubset(of: Set(fields.keys)),
                  !creating || required.isSubset(of: Set(value.keys)) else {
                throw NotebookToolError.invalid("Unknown or missing resource fields. Run 'lingrove schema'.")
            }
            var result = creating ? defaults : [:]
            for (key, value) in value {
                guard let field = fields[key] else { throw NotebookToolError.invalid("Unknown resource field.") }
                result[key] = try field.normalized(value)
            }
            return .object(result)
        }
        public var schema: [String: Any] {
            ["type": "object", "additionalProperties": false,
             "properties": fields.mapValues(\.schema), "required": Array(required).sorted()]
        }
    }
}
