import Foundation

/// Versioned values shared by the bundled command-line executable and app. The executable only
/// transports these values: domain validation and all notebook writes remain inside the app.
nonisolated struct CLIRequest: Codable, Sendable {
    enum Command: String, Codable, Sendable { case status, list, get, apply, resourceList, resourceGet }
    var version = 1
    var id = UUID()
    var expiresAt = Date().addingTimeInterval(30)
    var command: Command
    var query: String?
    var language: String?
    var limit: Int?
    var offset: Int?
    var entryID: UUID?
    var resource: String?
    var resourceID: UUID?
    var relatedID: UUID?
    var claimStatus: String?
    var batch: CLIBatch?
    var dryRun = false
}

/// One idempotency key describes one atomic batch. Appending is distinct from replacing fields,
/// so an agent cannot overwrite a user's meaning or note merely by capturing another example.
nonisolated struct CLIBatch: Codable, Sendable {
    var version: Int
    var idempotencyKey: String
    var expectedRevision: UInt64?
    var operations: [CLIChange]
}

nonisolated struct CLIChange: Codable, Sendable {
    var add: CLINewSense?
    var append: CLIAppend?
    var update: CLIUpdate?
    var put: CLIResourcePut?
    var delete: CLIResourceDelete?
    var capture: CLICapture?
}

/// Resource writes name stable caller-supplied UUIDs, so a single batch can create linked
/// records without guessing the IDs of earlier operations. The app validates typed domain
/// records; the executable shares only this bounded wire contract and never opens SQLite.
nonisolated struct CLIResourcePut: Codable, Sendable {
    var resource: String
    var value: CLIJSON
}

nonisolated struct CLIResourceDelete: Codable, Sendable {
    var resource: String
    var id: UUID
}

nonisolated struct CLINewSense: Codable, Sendable {
    var expression: String
    var language: String
    var kind: String
    var dictionaryForm: String?
    var meaning: String
    var meaningLanguage: String?
    var note: String?
    var tags: [String]?
    var examples: [CLIExample]?
    var content: [CLIBlock]?
}

nonisolated struct CLIAppend: Codable, Sendable {
    var entryID: UUID
    var senseID: UUID
    var examples: [CLIExample]?
    var content: [CLIBlock]?
    var tags: [String]?
}

nonisolated struct CLIUpdate: Codable, Sendable {
    var entryID: UUID
    var senseID: UUID
    var expectedRevision: UInt64
    var meaning: String?
    var meaningLanguage: String?
    var note: String?
    var tags: [String]?
}

nonisolated struct CLIExample: Codable, Sendable {
    struct Range: Codable, Sendable { var location: Int; var length: Int }
    var text: String
    var translation: String?
    var translationLanguage: String?
    var meaning: String?
    var meaningLanguage: String?
    var completeness: String?
    var sourceKind: String?
    var ranges: [Range]?
}

/// File paths exist only in CLI input. The executable reads explicitly supplied images and sends
/// bounded bytes; the app never opens an arbitrary path supplied by an automation request.
nonisolated struct CLIBlock: Codable, Sendable {
    var text: String?
    var image: Image?
    var bold: Bool?
    var italic: Bool?
    struct Image: Codable, Sendable {
        var path: String?
        var data: Data?
        var caption: String?
    }
}

/// JSON is confined to the wire envelope. Internally, domain code continues using typed Swift
/// values. Integer revisions avoid the rounding that an all-Double JSON representation causes.
nonisolated enum CLIJSON: Codable, Equatable, Sendable {
    case object([String: CLIJSON]), array([CLIJSON]), string(String), integer(Int64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
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
        } else if let object = try? value.decode([String: CLIJSON].self) {
            self = .object(object)
        } else {
            self = .array(try value.decode([CLIJSON].self))
        }
    }
    func encode(to encoder: Encoder) throws {
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
    static func value(_ value: some Encodable) throws -> Self { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
}

nonisolated struct CLIReply: Codable, Sendable {
    var version = 1
    var requestID: UUID
    var ok: Bool
    var result: CLIJSON?
    var error: CLIError?
    static func failure(_ id: UUID, _ error: CLIError) -> Self { .init(requestID: id, ok: false, error: error) }
}

/// Stable codes and exit statuses are for scripts; messages are technical English and never
/// include SQL, credentials or the submitted notebook content.
nonisolated struct CLIError: Error, Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable { case invalidInput = "invalid_input", notFound = "not_found", conflict,
        busy, unavailable, io, timeout }
    var code: Code
    var message: String
    var exitCode: Int32 {
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
    static func invalid(_ message: String) -> Self { .init(code: .invalidInput, message: message) }
}
