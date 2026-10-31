import Foundation
import LingroveNotebook

/// JSON values belong to the transport boundary, not to the notebook graph or a
/// SQLite payload. Public Sendable values can cross the host's IO task boundary;
/// this library does not choose an actor, create tasks or perform network IO.
public nonisolated indirect enum VocabularyWireJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String)
    case array([Self]), object([String: Self])

    public init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= 32 else { throw VocabularyWireError.invalidRecord }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else if let object = try? value.decode([String: Self].self) { self = .object(object) }
        else { throw VocabularyWireError.invalidRecord }
    }

    public func encode(to encoder: any Encoder) throws {
        guard encoder.codingPath.count <= 32 else { throw VocabularyWireError.invalidRecord }
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(bool): try value.encode(bool)
        case let .number(number):
            guard number.isFinite else { throw VocabularyWireError.invalidRecord }
            try value.encode(number)
        case let .string(string): try value.encode(string)
        case let .array(array): try value.encode(array)
        case let .object(object): try value.encode(object)
        }
    }
}

/// Explicit remote families match the version-one corpus contract. They do not
/// include the local codec's Anki binding family or derived searchable indexes.
public nonisolated enum VocabularyWireEntityKind: String, Codable, CaseIterable, Hashable, Sendable {
    case notebookSettings, entry, sense, source, occurrence, interpretation, collection
    case selectedInterpretation, senseExplanation, interpretationExplanation, contentBlock
    case reviewDraft, reviewTemplate, meaningNode, meaningLabel, meaningRole, usagePattern
    case patternSlot, meaningMapping, roleBinding, mappingEvidence, meaningRelation
    case retrievalCue, cueTarget, classificationFramework, category, categoryParent, categoryMembership, categoryOverride
}

/// One independently versionable domain entity. The surrounding sync layer owns
/// server clocks, tombstones and complete-window verification; these content
/// values never borrow a local revision as a cloud version.
public nonisolated struct VocabularyWireEntity: Codable, Equatable, Sendable {
    public let entityType: VocabularyWireEntityKind
    public let entityID: String
    public let fields: [String: VocabularyWireJSON]

    public init(entityType: VocabularyWireEntityKind, entityID: String, fields: [String: VocabularyWireJSON]) {
        self.entityType = entityType; self.entityID = entityID; self.fields = fields
    }

    public init(from decoder: any Decoder) throws {
        // A container keyed only by CodingKeys cannot see unrecognized keys.
        // Read raw key names first, so a full server row or a private overlay
        // cannot be mistaken for this deliberately smaller content envelope.
        let raw = try decoder.container(keyedBy: RawKey.self)
        guard Set(raw.allKeys.map(\.stringValue)) == Set(["entityType", "entityId", "fields"]) else {
            throw VocabularyWireError.invalidRecord
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entityType = try values.decode(VocabularyWireEntityKind.self, forKey: .entityType)
        entityID = try values.decode(String.self, forKey: .entityID)
        fields = try values.decode([String: VocabularyWireJSON].self, forKey: .fields)
    }

    private enum CodingKeys: String, CodingKey { case entityType, entityID = "entityId", fields }
    /// Dynamic keys exist only for strict envelope inspection during decoding.
    private struct RawKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// Errors contain codes, never rejected source text, endpoints or arbitrary keys.
public nonisolated enum VocabularyWireError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidDocument, invalidRecord, duplicateEntity
    case incompleteSnapshot, notebookMismatch, privateScopeMismatch
}

/// This result deliberately is not Codable: serializing a projection wholesale
/// must not accidentally upload the private overlay next to its public entities.
public nonisolated struct VocabularyWireProjection: Sendable {
    public let notebookID: UUID
    public let entities: [VocabularyWireEntity]
    public let privateState: VocabularyWirePrivateState
}

/// Unmatched local tool state is an explicit result, not discarded data. A host
/// must persist it locally together with the materialized document before it
/// acknowledges a window. This pure mapper does not commit either value.
public nonisolated struct VocabularyWireMaterialization: Sendable {
    public let document: VocabularyDocument
    public let unattachedPrivateState: VocabularyWirePrivateState
}

extension VocabularyWireJSON {
    /// Wire clocks describe literal values. Swift String equality folds Unicode
    /// normalization, which must not make changed source bytes look unchanged.
    func hasSameWireValue(as other: Self) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a.bitPattern == b.bitPattern
        case let (.string(a), .string(b)): return a.utf8.elementsEqual(b.utf8)
        case let (.array(a), .array(b)): return a.count == b.count && zip(a, b).allSatisfy { $0.hasSameWireValue(as: $1) }
        case let (.object(a), .object(b)):
            if a.count != b.count { return false }
            let right = Dictionary(uniqueKeysWithValues: b.map { (Data($0.key.utf8), $0.value) })
            return a.allSatisfy { key, value in right[Data(key.utf8)].map { value.hasSameWireValue(as: $0) } ?? false }
        default: return false
        }
    }
    // Historical local validation does not constrain every Date. Check the
    // entire public value before returning a projection so no in-memory NaN or
    // infinite date escapes as an entity that JSON/server validation cannot use.
    var hasFiniteNumbers: Bool {
        switch self {
        case let .number(value): value.isFinite
        case let .array(values): values.allSatisfy(\.hasFiniteNumbers)
        case let .object(values): values.values.allSatisfy(\.hasFiniteNumbers)
        case .null, .bool, .string: true
        }
    }
    static func uuid(_ value: UUID) -> Self { .string(value.uuidString.lowercased()) }
    static func date(_ value: Date) -> Self { .number(value.timeIntervalSinceReferenceDate) }
    static func rank(_ value: Int) -> Self { .number(Double(value)) }
    static func optional<T>(_ value: T?, _ transform: (T) -> Self) -> Self { value.map(transform) ?? .null }
}
