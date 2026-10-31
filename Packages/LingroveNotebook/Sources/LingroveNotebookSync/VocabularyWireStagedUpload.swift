import Foundation

/// Version-one private staging budgets match the backend storage declarations.
/// They grant no capability: the host still negotiates transport availability
/// and owns durable bytes, account generations and operation cancellation.
public nonisolated enum VocabularyWireStagedLimits {
    public static let maximumBodyBytes = 192 * 1024 * 1024
    public static let maximumMembers = 1_000_000
    public static let chunkBytes = 256 * 1024
    public static let confirmationMembersPerPage = 4096
}

public nonisolated enum VocabularyWireStagedError: Error, Equatable, Sendable {
    case invalidEnvelope, invalidManifest, expiredUpload, invalidConfirmation, invalidPage, incompleteConfirmation
}

/// One trusted batch plus its exact persisted body. The public-only planner and
/// restoration validate the target; this seam checks the frozen representation
/// without replacing it. A retry may re-encode a small chunk envelope but never
/// re-encode or change the original uploaded bytes/group identity.
public nonisolated struct VocabularyWireStagedUpload: Sendable {
    public let batch: VocabularyWireUploadBatch
    public let body: Data
    public let bodySHA256: String
    public let descriptorSHA256: String
    public var chunkCount: Int { (body.count - 1) / VocabularyWireStagedLimits.chunkBytes + 1 }

    public init(batch: VocabularyWireUploadBatch, frozenBody: Data) throws {
        guard batch.transport == .staged, !batch.scope.ownerUserID.utf8.isEmpty,
              !frozenBody.isEmpty, frozenBody.count <= VocabularyWireStagedLimits.maximumBodyBytes,
              try VocabularyWireGroupRequest.stagedRequest(from: frozenBody).hasSameRequest(as: batch.request) else {
            throw VocabularyWireStagedError.invalidEnvelope
        }
        self.batch = batch; body = frozenBody
        bodySHA256 = VocabularyWireWindowManifest.sha256(frozenBody)
        let owner = Data(batch.scope.ownerUserID.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let lines = ["lingrove-corpus-upload-v1", batch.scope.workspaceID.uuidString.lowercased(), batch.scope.notebookID.uuidString.lowercased(),
            batch.scope.replicaID.uuidString.lowercased(), batch.request.groupID.uuidString.lowercased(), owner, "1", bodySHA256,
            String(frozenBody.count), String(batch.request.members.count), String(VocabularyWireStagedLimits.chunkBytes),
            String((frozenBody.count - 1) / VocabularyWireStagedLimits.chunkBytes + 1), "base64", ""]
        descriptorSHA256 = VocabularyWireWindowManifest.sha256(Data(lines.joined(separator: "\n").utf8))
    }

    public func declarationBody() throws -> Data {
        try Self.encode(.object(["protocolVersion": .number(1), "notebookId": .uuid(batch.scope.notebookID),
            "replicaId": .uuid(batch.scope.replicaID), "groupId": .uuid(batch.request.groupID), "bodySha256": .string(bodySHA256),
            "byteCount": .number(Double(body.count)), "memberCount": .number(Double(batch.request.members.count))]))
    }
    public func identityBody() throws -> Data { try Self.encode(.object(identity)) }
    public func chunkBody(_ ordinal: Int) throws -> Data {
        guard ordinal >= 0, ordinal < chunkCount else { throw VocabularyWireStagedError.invalidEnvelope }
        let offset = body.startIndex + ordinal * VocabularyWireStagedLimits.chunkBytes
        let bytes = body.subdata(in: offset..<min(body.endIndex, offset + VocabularyWireStagedLimits.chunkBytes))
        var fields = identity
        fields["ordinal"] = .number(Double(ordinal)); fields["data"] = .string(bytes.base64EncodedString())
        fields["sha256"] = .string(VocabularyWireWindowManifest.sha256(bytes)); fields["byteCount"] = .number(Double(bytes.count))
        return try Self.encode(.object(fields))
    }
    public func confirmationPageBody(_ ordinal: Int, manifest: VocabularyWireConfirmationManifest) throws -> Data {
        try manifest.validate(for: self)
        guard ordinal >= 0, ordinal < manifest.pageCount else { throw VocabularyWireStagedError.invalidPage }
        var fields = identity; fields["ordinal"] = .number(Double(ordinal)); fields["manifestSha256"] = .string(manifest.manifestSHA256)
        return try Self.encode(.object(fields))
    }
    private var identity: [String: VocabularyWireJSON] {
        ["notebookId": .uuid(batch.scope.notebookID), "replicaId": .uuid(batch.scope.replicaID),
         "groupId": .uuid(batch.request.groupID), "descriptorSha256": .string(descriptorSHA256)]
    }
    private static func encode(_ json: VocabularyWireJSON) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(json)
    }
}

/// Upload progress is not a group outcome, even when all chunks arrived or the
/// state says finalized. Only complete confirmation verification can produce an
/// outcome; aborted/expired transport identities retain all local journals.
public nonisolated struct VocabularyWireStagedManifest: Decodable, Sendable {
    public enum State: String, Sendable { case open, aborted, expired, finalized }
    public let workspaceID: UUID
    public let notebookID: UUID
    public let replicaID: UUID
    public let groupID: UUID
    public let bodySHA256: String
    public let descriptorSHA256: String
    public let byteCount: Int
    public let memberCount: Int
    public let chunkCount: Int
    public let state: State
    public let receivedOrdinals: [Int]
    public let payloadRetired: Bool
    private let createdAt: Date
    private let expiresAt: Date

    public init(from decoder: any Decoder) throws {
        var f = try VocabularyWireFields(VocabularyWireJSON(from: decoder))
        guard try f.integer("protocolVersion") == 1 else { throw VocabularyWireStagedError.invalidManifest }
        workspaceID = try f.uuid("workspaceId"); notebookID = try f.uuid("notebookId"); replicaID = try f.uuid("replicaId"); groupID = try f.uuid("groupId")
        bodySHA256 = try f.string("bodySha256"); descriptorSHA256 = try f.string("descriptorSha256")
        byteCount = try f.integer("byteCount", maximum: VocabularyWireStagedLimits.maximumBodyBytes, minimum: 1)
        memberCount = try f.integer("memberCount", maximum: VocabularyWireStagedLimits.maximumMembers, minimum: 1)
        chunkCount = try f.integer("chunkCount", maximum: 768, minimum: 1)
        guard try f.integer("chunkBytes") == VocabularyWireStagedLimits.chunkBytes,
              let state = State(rawValue: try f.string("state")) else { throw VocabularyWireStagedError.invalidManifest }
        self.state = state
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let created = try f.string("createdAt"), expires = try f.string("expiresAt")
        guard let createdAt = formatter.date(from: created), let expiresAt = formatter.date(from: expires),
              formatter.string(from: createdAt) == created, formatter.string(from: expiresAt) == expires,
              expiresAt.timeIntervalSince(createdAt) == 900 else { throw VocabularyWireStagedError.invalidManifest }
        self.createdAt = createdAt; self.expiresAt = expiresAt
        let chunks = chunkCount
        receivedOrdinals = try f.array("receivedOrdinals").map {
            guard case let .number(value) = $0, value >= 0, value < Double(chunks), value.rounded(.towardZero) == value else {
                throw VocabularyWireStagedError.invalidManifest
            }
            return Int(value)
        }
        payloadRetired = try f.bool("payloadRetired"); try f.finish()
        guard chunkCount == (byteCount - 1) / VocabularyWireStagedLimits.chunkBytes + 1,
              VocabularyWireWindowManifest.isSHA256(bodySHA256), VocabularyWireWindowManifest.isSHA256(descriptorSHA256),
              receivedOrdinals.count <= chunkCount, receivedOrdinals == receivedOrdinals.sorted(), Set(receivedOrdinals).count == receivedOrdinals.count,
              state == .open ? !payloadRetired : receivedOrdinals.isEmpty else { throw VocabularyWireStagedError.invalidManifest }
    }
    public func validate(for upload: VocabularyWireStagedUpload, now: Date) throws {
        guard workspaceID == upload.batch.scope.workspaceID, notebookID == upload.batch.scope.notebookID, replicaID == upload.batch.scope.replicaID,
              groupID == upload.batch.request.groupID, bodySHA256 == upload.bodySHA256, descriptorSHA256 == upload.descriptorSHA256,
              byteCount == upload.body.count, memberCount == upload.batch.request.members.count, chunkCount == upload.chunkCount,
              now.timeIntervalSinceReferenceDate.isFinite else { throw VocabularyWireStagedError.invalidManifest }
        if state == .open, now >= expiresAt { throw VocabularyWireStagedError.expiredUpload }
    }
}
