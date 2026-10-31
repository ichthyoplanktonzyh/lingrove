import Foundation

/// A permanent compact decision, not yet a receipt. Its hashes bind the raw
/// frozen request, exact owner bytes and every member/page. No lease or current
/// book cursor participates, so verification can resume after upload cleanup.
public nonisolated struct VocabularyWireConfirmationManifest: Codable, Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case committed(VocabularyWireSequence)
        case rejected(VocabularyWireGroupRejection.Reason)
    }
    public let scope: VocabularyWireWindowScope
    public let groupID: UUID
    public let descriptorSHA256: String
    public let bodySHA256: String
    public let bodyByteCount: Int
    public let canonicalSHA256: String
    public let memberIDsSHA256: String
    public let pagesSHA256: String
    public let memberCount: Int
    public let pageCount: Int
    public let decision: Decision
    public let manifestSHA256: String

    public init(from decoder: any Decoder) throws {
        var f = try VocabularyWireFields(VocabularyWireJSON(from: decoder))
        guard try f.integer("protocolVersion") == 1 else { throw VocabularyWireStagedError.invalidConfirmation }
        scope = .init(ownerUserID: try f.string("ownerUserId"), workspaceID: try f.uuid("workspaceId"),
            notebookID: try f.uuid("notebookId"), replicaID: try f.uuid("replicaId"))
        groupID = try f.uuid("groupId"); descriptorSHA256 = try f.string("descriptorSha256"); bodySHA256 = try f.string("bodySha256")
        bodyByteCount = try f.integer("bodyByteCount", maximum: VocabularyWireStagedLimits.maximumBodyBytes, minimum: 1)
        canonicalSHA256 = try f.string("canonicalSha256"); memberIDsSHA256 = try f.string("memberIdsSha256"); pagesSHA256 = try f.string("pagesSha256")
        memberCount = try f.integer("memberCount", maximum: VocabularyWireStagedLimits.maximumMembers, minimum: 1)
        pageCount = try f.integer("pageCount", maximum: 245, minimum: 1)
        guard try f.integer("membersPerPage") == VocabularyWireStagedLimits.confirmationMembersPerPage else { throw VocabularyWireStagedError.invalidConfirmation }
        let status = try f.string("status")
        let sequence = try f.optional("committedSequence") { try VocabularyWireSequence(VocabularyWireFields.string($0)) }
        let reason = try f.optional("rejectionReason", VocabularyWireFields.string)
        switch status {
        case "committed":
            guard let sequence, sequence > .zero, reason == nil else { throw VocabularyWireStagedError.invalidConfirmation }
            decision = .committed(sequence)
        case "rejected":
            guard sequence == nil, let reason, let value = VocabularyWireGroupRejection.Reason(rawValue: reason) else { throw VocabularyWireStagedError.invalidConfirmation }
            decision = .rejected(value)
        default: throw VocabularyWireStagedError.invalidConfirmation
        }
        manifestSHA256 = try f.string("manifestSha256"); try f.finish()
        guard pageCount == (memberCount - 1) / VocabularyWireStagedLimits.confirmationMembersPerPage + 1,
              [descriptorSHA256, bodySHA256, canonicalSHA256, memberIDsSHA256, pagesSHA256, manifestSHA256].allSatisfy(VocabularyWireWindowManifest.isSHA256),
              calculatedDigest == manifestSHA256 else { throw VocabularyWireStagedError.invalidConfirmation }
    }

    public func validate(for upload: VocabularyWireStagedUpload) throws {
        guard scope == upload.batch.scope, groupID == upload.batch.request.groupID, descriptorSHA256 == upload.descriptorSHA256,
              bodySHA256 == upload.bodySHA256, bodyByteCount == upload.body.count, memberCount == upload.batch.request.members.count else {
            throw VocabularyWireStagedError.invalidConfirmation
        }
        if case let .committed(sequence) = decision, sequence <= upload.batch.baseSequence { throw VocabularyWireStagedError.invalidConfirmation }
    }
    private var decisionFields: (status: String, sequence: String?, reason: String?) {
        switch decision {
        case let .committed(sequence): ("committed", sequence.rawValue, nil)
        case let .rejected(reason): ("rejected", nil, reason.rawValue)
        }
    }
    private var calculatedDigest: String {
        let owner = Data(scope.ownerUserID.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let fields = decisionFields
        let lines = ["lingrove-corpus-confirmation:1", scope.workspaceID.uuidString.lowercased(), owner,
            scope.notebookID.uuidString.lowercased(), scope.replicaID.uuidString.lowercased(), groupID.uuidString.lowercased(), descriptorSHA256,
            bodySHA256, String(bodyByteCount), canonicalSHA256, memberIDsSHA256, pagesSHA256, String(memberCount), fields.status,
            fields.sequence ?? "-", fields.reason ?? "-", String(VocabularyWireStagedLimits.confirmationMembersPerPage), String(pageCount), ""]
        return VocabularyWireWindowManifest.sha256(Data(lines.joined(separator: "\n").utf8))
    }
    public func encode(to encoder: any Encoder) throws {
        let fields = decisionFields
        try VocabularyWireJSON.object(["protocolVersion": .number(1), "workspaceId": .uuid(scope.workspaceID), "ownerUserId": .string(scope.ownerUserID),
            "notebookId": .uuid(scope.notebookID), "replicaId": .uuid(scope.replicaID), "groupId": .uuid(groupID),
            "descriptorSha256": .string(descriptorSHA256), "bodySha256": .string(bodySHA256), "bodyByteCount": .number(Double(bodyByteCount)),
            "canonicalSha256": .string(canonicalSHA256), "memberIdsSha256": .string(memberIDsSHA256), "pagesSha256": .string(pagesSHA256),
            "memberCount": .number(Double(memberCount)), "pageCount": .number(Double(pageCount)),
            "membersPerPage": .number(Double(VocabularyWireStagedLimits.confirmationMembersPerPage)), "status": .string(fields.status),
            "committedSequence": fields.sequence.map(VocabularyWireJSON.string) ?? .null,
            "rejectionReason": fields.reason.map(VocabularyWireJSON.string) ?? .null, "manifestSha256": .string(manifestSHA256)]).encode(to: encoder)
    }
}

/// Only one bounded page is decoded at a time. Page-local integrity is useful
/// for durable staging, but its group/manifest identity and complete stream still
/// have to be checked against the independent frozen request.
public nonisolated struct VocabularyWireConfirmationPage: Codable, Equatable, Sendable {
    public let groupID: UUID
    public let manifestSHA256: String
    public let ordinal: Int
    public let firstMemberOrdinal: Int
    public let memberCount: Int
    public let data: String
    public let byteCount: Int
    public let sha256: String
    public init(from decoder: any Decoder) throws {
        var f = try VocabularyWireFields(VocabularyWireJSON(from: decoder))
        groupID = try f.uuid("groupId"); manifestSHA256 = try f.string("manifestSha256")
        ordinal = try f.integer("ordinal", maximum: 244); firstMemberOrdinal = try f.integer("firstMemberOrdinal", maximum: 999_999)
        memberCount = try f.integer("memberCount", maximum: VocabularyWireStagedLimits.confirmationMembersPerPage, minimum: 1)
        guard try f.string("encoding") == "base64" else { throw VocabularyWireStagedError.invalidPage }
        data = try f.string("data"); byteCount = try f.integer("byteCount", maximum: 37 * VocabularyWireStagedLimits.confirmationMembersPerPage, minimum: 37)
        sha256 = try f.string("sha256"); try f.finish()
        guard firstMemberOrdinal == ordinal * VocabularyWireStagedLimits.confirmationMembersPerPage,
              byteCount == memberCount * 37, data.utf8.count == ((byteCount + 2) / 3) * 4,
              VocabularyWireWindowManifest.isSHA256(sha256), VocabularyWireWindowManifest.isSHA256(manifestSHA256) else { throw VocabularyWireStagedError.invalidPage }
    }
    func verified(for manifest: VocabularyWireConfirmationManifest, upload: VocabularyWireStagedUpload) throws -> (bytes: Data, members: [UUID]) {
        try manifest.validate(for: upload)
        let expected = min(VocabularyWireStagedLimits.confirmationMembersPerPage, manifest.memberCount - firstMemberOrdinal)
        guard groupID == manifest.groupID, manifestSHA256 == manifest.manifestSHA256, ordinal < manifest.pageCount,
              memberCount == expected, let bytes = Data(base64Encoded: data), bytes.base64EncodedString() == data,
              bytes.count == byteCount, VocabularyWireWindowManifest.sha256(bytes) == sha256,
              let text = String(data: bytes, encoding: .ascii) else { throw VocabularyWireStagedError.invalidPage }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == expected + 1, lines.last?.isEmpty == true else { throw VocabularyWireStagedError.invalidPage }
        let members = try lines.dropLast().map { line in
            guard line.utf8.count == 36 else { throw VocabularyWireStagedError.invalidPage }
            return try VocabularyWireFields.uuid(String(line))
        }
        return (bytes, members)
    }
    /// A host may durably stage one bounded page without replaying all prior
    /// pages or reparsing the large frozen body. This proves page-local identity
    /// and exact frozen members; only the accumulator proves the complete root.
    public func validate(for manifest: VocabularyWireConfirmationManifest, upload: VocabularyWireStagedUpload) throws {
        let checked = try verified(for: manifest, upload: upload)
        guard firstMemberOrdinal <= upload.batch.request.members.count,
              checked.members.count <= upload.batch.request.members.count - firstMemberOrdinal,
              zip(upload.batch.request.members[firstMemberOrdinal..<(firstMemberOrdinal + checked.members.count)], checked.members)
                .allSatisfy({ $0.memberID == $1 }) else { throw VocabularyWireStagedError.invalidPage }
    }
    public func encode(to encoder: any Encoder) throws {
        try VocabularyWireJSON.object(["groupId": .uuid(groupID), "manifestSha256": .string(manifestSHA256), "ordinal": .number(Double(ordinal)),
            "firstMemberOrdinal": .number(Double(firstMemberOrdinal)), "memberCount": .number(Double(memberCount)), "encoding": .string("base64"),
            "data": .string(data), "byteCount": .number(Double(byteCount)), "sha256": .string(sha256)]).encode(to: encoder)
    }
}
