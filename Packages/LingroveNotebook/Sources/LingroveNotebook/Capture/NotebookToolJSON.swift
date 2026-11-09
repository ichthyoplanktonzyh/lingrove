import Foundation

/// JSON is confined to the wire envelope. Internally, domain code continues using typed Swift
/// values. Integer revisions avoid the rounding that an all-Double JSON representation causes.
public nonisolated enum NotebookToolJSON: Codable, Equatable, Sendable {
    case object([String: NotebookToolJSON]), array([NotebookToolJSON]), string(String), integer(Int64), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let boolean = try? value.decode(Bool.self) {
            self = .bool(boolean)
        } else if let integer = try? value.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let object = try? value.decode([String: NotebookToolJSON].self) {
            self = .object(object)
        } else {
            self = .array(try value.decode([NotebookToolJSON].self))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(object): try value.encode(object)
        case let .array(array): try value.encode(array)
        case let .string(string): try value.encode(string)
        case let .integer(integer): try value.encode(integer)
        case let .number(number): try value.encode(number)
        case let .bool(boolean): try value.encode(boolean)
        case .null: try value.encodeNil()
        }
    }
    public static func value(_ value: some Encodable) throws -> Self { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
}

/// Stable codes and exit statuses are for scripts; messages are technical English and never
/// include SQL, credentials or the submitted notebook content.
public nonisolated struct NotebookToolError: Error, Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable { case invalidInput = "invalid_input", notFound = "not_found", conflict,
        busy, unavailable, io, timeout }
    public var code: Code
    public var message: String
    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    public var exitCode: Int32 {
        switch code {
        case .invalidInput: 2
        case .notFound: 3
        case .conflict: 4
        case .busy: 5
        case .unavailable: 6
        case .io: 7
        case .timeout: 8
        }
    }
    public static func invalid(_ message: String) -> Self { .init(code: .invalidInput, message: message) }
}
