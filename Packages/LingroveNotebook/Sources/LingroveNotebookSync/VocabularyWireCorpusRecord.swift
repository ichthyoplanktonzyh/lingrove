import Foundation

/// Confirmed server metadata is separate from the public lexical entity and all
/// device-private tool state. The app's shadow persists these values; views and
/// the domain materializer consume only live `entity` projections.
public nonisolated struct VocabularyWireCorpusRecord: Codable, Equatable, Sendable {
    public let entity: VocabularyWireEntity
    public let version: VocabularyWireSequence
    public let deleted: Bool
    public let fieldVersions: [String: VocabularyWireSequence]
    public let fieldResets: [String: VocabularyWireSequence]
    public init(from decoder: any Decoder) throws {
        var f = try VocabularyWireFields(VocabularyWireJSON(from: decoder))
        guard let kind = VocabularyWireEntityKind(rawValue: try f.string("entityType")) else { throw VocabularyWireWindowError.invalidRecord }
        let id = try f.string("entityId")
        guard case let .object(fields) = try f.take("fields") else { throw VocabularyWireWindowError.invalidRecord }
        entity = .init(entityType: kind, entityID: id, fields: fields)
        version = try .init(f.string("version")); deleted = try f.bool("deleted")
        func clocks(_ value: VocabularyWireJSON) throws -> [String: VocabularyWireSequence] {
            guard case let .object(values) = value else { throw VocabularyWireWindowError.invalidRecord }
            return try values.mapValues { try VocabularyWireSequence(VocabularyWireFields.string($0)) }
        }
        fieldVersions = try clocks(f.take("fieldVersions")); fieldResets = try clocks(f.take("fieldResets")); try f.finish()
        guard version > .zero, Set(fields.keys) == Set(fieldVersions.keys), Set(fields.keys) == Set(fieldResets.keys),
              !deleted || fields.isEmpty else { throw VocabularyWireWindowError.invalidRecord }
        for key in fields.keys {
            guard let clock = fieldVersions[key], let reset = fieldResets[key], reset > .zero, reset <= clock, clock <= version else { throw VocabularyWireWindowError.invalidRecord }
        }
        try validateIdentity()
    }
    public func encode(to encoder: any Encoder) throws {
        try VocabularyWireJSON.object(["entityType": .string(entity.entityType.rawValue), "entityId": .string(entity.entityID), "fields": .object(entity.fields),
            "version": .string(version.rawValue), "deleted": .bool(deleted),
            "fieldVersions": .object(fieldVersions.mapValues { .string($0.rawValue) }), "fieldResets": .object(fieldResets.mapValues { .string($0.rawValue) })]).encode(to: encoder)
    }
    var key: String { entity.entityType.rawValue + ":" + entity.entityID }
    func hasSameWireValue(as other: Self) -> Bool {
        entity.entityType == other.entity.entityType && entity.entityID == other.entity.entityID && version == other.version
            && deleted == other.deleted && fieldVersions == other.fieldVersions && fieldResets == other.fieldResets
            && VocabularyWireJSON.object(entity.fields).hasSameWireValue(as: .object(other.entity.fields))
    }
    private func validateIdentity() throws {
        let id = entity.entityID, kind = entity.entityType
        let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        let composite: Set<VocabularyWireEntityKind> = [.selectedInterpretation, .senseExplanation, .interpretationExplanation, .mappingEvidence]
        let grammar = kind == .reviewDraft ? "\(uuid):(legacy|card:\(uuid))" : composite.contains(kind) ? "\(uuid):\(uuid)" : uuid
        guard let match = id.range(of: "^\(grammar)$", options: .regularExpression), match == id.startIndex..<id.endIndex,
              !(deleted && kind == .notebookSettings) else { throw VocabularyWireWindowError.invalidRecord }
        guard !deleted else { return }
        var f = VocabularyWireFields(entity.fields)
        let expected: String
        switch kind {
        case .selectedInterpretation: expected = try f.string("senseId") + ":" + f.string("interpretationId")
        case .senseExplanation: expected = try f.string("senseId") + ":" + f.string("explanationId")
        case .interpretationExplanation: expected = try f.string("interpretationId") + ":" + f.string("explanationId")
        case .mappingEvidence: expected = try f.string("mappingId") + ":" + f.string("interpretationId")
        case .reviewDraft:
            let owner = try f.string("senseId"), role = try f.string("role")
            if role == "legacy" { expected = owner + ":legacy" }
            else {
                guard role == "card" else { throw VocabularyWireWindowError.invalidRecord }
                var plan = try VocabularyWireFields(f.take("plan")); expected = try owner + ":card:" + plan.string("id")
            }
        default: return
        }
        guard expected == id else { throw VocabularyWireWindowError.invalidRecord }
    }
}
