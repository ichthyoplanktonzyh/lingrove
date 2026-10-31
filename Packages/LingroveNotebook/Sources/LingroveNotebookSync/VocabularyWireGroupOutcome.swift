import Foundation

/// A negative confirmation proves that this exact group can never commit. It
/// carries identity and ordered coverage, not a replacement document or cursor.
/// The host must match it to the persisted batch before changing local state.
public nonisolated struct VocabularyWireGroupRejection: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case entityConflict = "entity_conflict"
        case invalidCorpus = "invalid_corpus"
        case cancelled
    }
    public let notebookID: UUID
    public let groupID: UUID
    public let memberIDs: [UUID]
    public let reason: Reason

    public init(from decoder: any Decoder) throws {
        try self.init(VocabularyWireJSON(from: decoder))
    }
    init(_ json: VocabularyWireJSON) throws {
        var fields = try VocabularyWireFields(json)
        guard try fields.integer("protocolVersion") == 1 else { throw VocabularyWireUploadError.receiptMismatch }
        notebookID = try fields.uuid("notebookId"); groupID = try fields.uuid("groupId")
        memberIDs = try fields.array("memberIds").map { try VocabularyWireFields.uuid(VocabularyWireFields.string($0)) }
        guard let reason = try Reason(rawValue: fields.string("reason")) else { throw VocabularyWireUploadError.receiptMismatch }
        self.reason = reason
        try fields.finish()
        guard !memberIDs.isEmpty, memberIDs.count <= 10_000, Set(memberIDs).count == memberIDs.count else {
            throw VocabularyWireUploadError.receiptMismatch
        }
    }
    var json: VocabularyWireJSON {
        .object(["protocolVersion": .number(1), "notebookId": .uuid(notebookID), "groupId": .uuid(groupID),
            "memberIds": .array(memberIDs.map(VocabularyWireJSON.uuid)), "reason": .string(reason.rawValue)])
    }
    public func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }
    public func validate(for batch: VocabularyWireUploadBatch) throws {
        guard notebookID == batch.request.notebookID, groupID == batch.request.groupID,
              memberIDs == batch.request.members.map(\.memberID) else { throw VocabularyWireUploadError.receiptMismatch }
    }
}

/// The transport returns one closed alternative. Ordinary HTTP/auth/SQL errors
/// never decode as this value and therefore never authorize dropping a batch.
public nonisolated enum VocabularyWireGroupOutcome: Codable, Equatable, Sendable {
    case committed(VocabularyWireGroupReceipt)
    case rejected(VocabularyWireGroupRejection)

    public init(from decoder: any Decoder) throws {
        var fields = try VocabularyWireFields(VocabularyWireJSON(from: decoder))
        switch try fields.string("status") {
        case "committed": self = .committed(try VocabularyWireGroupReceipt(fields.take("receipt")))
        case "rejected": self = .rejected(try VocabularyWireGroupRejection(fields.take("rejection")))
        default: throw VocabularyWireUploadError.receiptMismatch
        }
        try fields.finish()
    }
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .committed(value):
            try VocabularyWireJSON.object(["status": .string("committed"), "receipt": value.json]).encode(to: encoder)
        case let .rejected(value):
            try VocabularyWireJSON.object(["status": .string("rejected"), "rejection": value.json]).encode(to: encoder)
        }
    }
    public func validate(for batch: VocabularyWireUploadBatch) throws {
        switch self {
        case let .committed(value): try value.validate(for: batch)
        case let .rejected(value): try value.validate(for: batch)
        }
    }
}
