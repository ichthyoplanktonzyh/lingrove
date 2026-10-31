import Foundation

public nonisolated enum VocabularyWireUploadError: Error, Equatable, Sendable {
    case invalidRequest, requestTooLarge, invalidTransition, retiredIdentity, receiptMismatch, incompleteReceiptCoverage
}

/// Planner-created mutations contain only explicit public corpus fields, never
/// SQLite payloads or private overlays. A decoded DTO remains untrusted until
/// batch restoration validates it against its full target and confirmed graph;
/// networking consumes the trusted batch, not an arbitrary decoded request.
public nonisolated struct VocabularyWireMutation: Codable, Sendable {
    public enum Action: Sendable {
        case create([String: VocabularyWireJSON])
        case patch(set: [String: VocabularyWireJSON], add: [String: VocabularyWireJSON])
        case delete
    }
    public let entityType: VocabularyWireEntityKind
    public let entityID: String
    public let baseVersion: VocabularyWireSequence
    public let action: Action
    var key: String { entityType.rawValue + ":" + entityID }
    init(entityType: VocabularyWireEntityKind, entityID: String, baseVersion: VocabularyWireSequence, action: Action) {
        self.entityType = entityType; self.entityID = entityID; self.baseVersion = baseVersion; self.action = action
    }
    public init(from decoder: any Decoder) throws { try self.init(VocabularyWireJSON(from: decoder)) }
    init(_ json: VocabularyWireJSON) throws {
        var f = try VocabularyWireFields(json)
        guard try f.string("domain") == "corpus", let kind = VocabularyWireEntityKind(rawValue: try f.string("entityType")) else { throw VocabularyWireUploadError.invalidRequest }
        entityType = kind; entityID = try f.string("entityId"); baseVersion = try .init(f.string("baseVersion"))
        func object(_ value: VocabularyWireJSON) throws -> [String: VocabularyWireJSON] {
            guard case let .object(fields) = value else { throw VocabularyWireUploadError.invalidRequest }; return fields
        }
        switch try f.string("action") {
        case "create":
            guard baseVersion == .zero else { throw VocabularyWireUploadError.invalidRequest }
            action = .create(try object(f.take("fields")))
        case "patch":
            guard baseVersion > .zero else { throw VocabularyWireUploadError.invalidRequest }
            let set = try object(f.take("set")), add = try object(f.take("add"))
            guard !set.isEmpty || !add.isEmpty, Set(set.keys).isDisjoint(with: Set(add.keys)),
                  add.allSatisfy({ field, value in
                      if case .array = value { return VocabularyWireMutationPolicy.isAdditive(kind, field) }; return false
                  }) else { throw VocabularyWireUploadError.invalidRequest }
            action = .patch(set: set, add: add)
        case "delete":
            guard baseVersion > .zero else { throw VocabularyWireUploadError.invalidRequest }; action = .delete
        default: throw VocabularyWireUploadError.invalidRequest
        }
        try f.finish()
    }
    var json: VocabularyWireJSON {
        var fields: [String: VocabularyWireJSON] = ["domain": .string("corpus"), "entityType": .string(entityType.rawValue),
            "entityId": .string(entityID), "baseVersion": .string(baseVersion.rawValue)]
        switch action {
        case let .create(values): fields["action"] = .string("create"); fields["fields"] = .object(values)
        case let .patch(set, add): fields["action"] = .string("patch"); fields["set"] = .object(set); fields["add"] = .object(add)
        case .delete: fields["action"] = .string("delete")
        }
        return .object(fields)
    }
    public func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }
    var writtenFields: Set<String> {
        switch action {
        case let .create(fields): Set(fields.keys)
        case let .patch(set, add): Set(set.keys).union(add.keys)
        case .delete: []
        }
    }
}

/// Frozen group identity and ordered coverage, matching the existing server
/// contract. The host persists its encoded bytes once and reuses them after a
/// timeout/restart instead of allocating a fresh operation identity.
public nonisolated struct VocabularyWireGroupRequest: Codable, Sendable {
    public struct Member: Sendable {
        public let memberID: UUID
        public let change: VocabularyWireMutation
    }
    public let notebookID: UUID
    public let groupID: UUID
    public let replicaID: UUID
    public let members: [Member]
    init(notebookID: UUID, groupID: UUID, replicaID: UUID, members: [Member]) {
        self.notebookID = notebookID; self.groupID = groupID; self.replicaID = replicaID; self.members = members
    }
    public init(from decoder: any Decoder) throws {
        var f = try VocabularyWireFields(VocabularyWireJSON(from: decoder))
        guard try f.integer("protocolVersion") == 1 else { throw VocabularyWireUploadError.invalidRequest }
        notebookID = try f.uuid("notebookId"); groupID = try f.uuid("groupId"); replicaID = try f.uuid("replicaId")
        members = try f.array("members").map { value in
            var m = try VocabularyWireFields(value)
            let id = try m.uuid("memberId"), change = try VocabularyWireMutation(m.take("change"))
            try m.finish(); return Member(memberID: id, change: change)
        }
        try f.finish()
        guard !members.isEmpty, members.count <= 10_000,
              Set(members.map(\.memberID)).count == members.count,
              Set(members.map(\.change.key)).count == members.count else { throw VocabularyWireUploadError.invalidRequest }
    }
    public func encode(to encoder: any Encoder) throws {
        try VocabularyWireJSON.object(["protocolVersion": .number(1), "notebookId": .uuid(notebookID), "groupId": .uuid(groupID), "replicaId": .uuid(replicaID),
            "members": .array(members.map { .object(["memberId": .uuid($0.memberID), "change": $0.change.json]) })]).encode(to: encoder)
    }
    func encodedBody() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        // This bounds the actual native request. The server independently checks
        // its canonical group budget (including workspace framing); 413 remains
        // an explicit error, never permission to split a relationship graph.
        guard members.count <= 10_000, bytes.count <= 2 * 1024 * 1024 else { throw VocabularyWireUploadError.requestTooLarge }
        return bytes
    }
}

/// A receipt is useful only after matching the exact group and every ordered
/// member. Its cursor proves a commit, not the canonical field values to apply.
public nonisolated struct VocabularyWireGroupReceipt: Codable, Equatable, Sendable {
    public let notebookID: UUID
    public let groupID: UUID
    public let committedSequence: VocabularyWireSequence
    public let memberIDs: [UUID]
    public init(from decoder: any Decoder) throws {
        try self.init(VocabularyWireJSON(from: decoder))
    }
    init(_ json: VocabularyWireJSON) throws {
        var f = try VocabularyWireFields(json)
        guard try f.integer("protocolVersion") == 1 else { throw VocabularyWireUploadError.receiptMismatch }
        notebookID = try f.uuid("notebookId"); groupID = try f.uuid("groupId"); committedSequence = try .init(f.string("committedSequence"))
        memberIDs = try f.array("memberIds").map { try VocabularyWireFields.uuid(VocabularyWireFields.string($0)) }
        try f.finish()
        guard committedSequence > .zero, !memberIDs.isEmpty, memberIDs.count <= 10_000,
              Set(memberIDs).count == memberIDs.count else { throw VocabularyWireUploadError.receiptMismatch }
    }
    var json: VocabularyWireJSON {
        .object(["protocolVersion": .number(1), "notebookId": .uuid(notebookID), "groupId": .uuid(groupID),
            "committedSequence": .string(committedSequence.rawValue), "memberIds": .array(memberIDs.map(VocabularyWireJSON.uuid))])
    }
    public func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }
    public func validate(for batch: VocabularyWireUploadBatch) throws {
        guard notebookID == batch.request.notebookID, groupID == batch.request.groupID,
              committedSequence > batch.baseSequence, memberIDs == batch.request.members.map(\.memberID) else { throw VocabularyWireUploadError.receiptMismatch }
    }
}

/// Version-one additive inventory is shared by planning and local overlay. The
/// server owns final validation; this small policy only distinguishes append
/// intent from a deliberate replacement/removal in a native request.
nonisolated enum VocabularyWireMutationPolicy {
    static func isAdditive(_ kind: VocabularyWireEntityKind, _ field: String) -> Bool {
        switch kind {
        case .sense: ["mergedFrom", "standaloneMeanings", "alternateMeanings"].contains(field)
        case .collection: field == "tags"
        case .interpretation: field == "translationVariants"
        case .usagePattern: field == "collocations"
        case .category: ["examples", "references", "localizations"].contains(field)
        default: false
        }
    }
}
