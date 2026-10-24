import Foundation

/// Only JSON values cross the HTTP boundary. In particular NSNumber booleans never masquerade
/// as note IDs. The protocol lets acceptance tests exercise real controller transactions with
/// an isolated Anki server instead of touching the user's collection.
nonisolated enum AnkiValue: Codable, Equatable, Sendable {
    case object([String: AnkiValue]), array([AnkiValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([AnkiValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AnkiValue].self))
        }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    var object: [String: AnkiValue]? { if case let .object(value) = self { value } else { nil } }
    var array: [AnkiValue]? { if case let .array(value) = self { value } else { nil } }
    var string: String? { if case let .string(value) = self { value } else { nil } }
    var integer: Int64? {
        guard case let .number(value) = self, value.isFinite, value > 0, value < Double(Int64.max),
              value.rounded(.towardZero) == value else { return nil }
        return Int64(value)
    }
    static func strings(_ values: [String: String]) -> AnkiValue { .object(values.mapValues(AnkiValue.string)) }
    static func list(_ values: [String]) -> AnkiValue { .array(values.map(AnkiValue.string)) }
}

nonisolated protocol AnkiConnecting: Sendable {
    func perform(_ action: String, params: [String: AnkiValue], connection: AnkiConnection) async throws -> AnkiValue
}
