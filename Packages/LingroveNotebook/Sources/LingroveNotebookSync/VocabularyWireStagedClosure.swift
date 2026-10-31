import Foundation

/// A permanent transport closure, deliberately distinct from a group outcome.
/// It is created only from a validated server manifest; after disk restoration
/// the host validates it again against the independent frozen envelope. Lease
/// and cleanup progress are excluded because they cannot change this decision.
public nonisolated struct VocabularyWireStagedClosure: Codable, Equatable, Sendable {
    public enum Reason: String, Sendable { case aborted, expired }
    public let scope: VocabularyWireWindowScope
    public let groupID: UUID
    public let reason: Reason
    public let descriptorSHA256: String
    public let bodySHA256: String
    public let bodyByteCount: Int
    public let memberCount: Int
    public var closureSHA256: String {
        let owner = Data(scope.ownerUserID.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let lines = ["lingrove-corpus-upload-closure:1", scope.workspaceID.uuidString.lowercased(), owner,
            scope.notebookID.uuidString.lowercased(), scope.replicaID.uuidString.lowercased(), groupID.uuidString.lowercased(),
            descriptorSHA256, bodySHA256, String(bodyByteCount), String(memberCount), reason.rawValue, ""]
        return VocabularyWireWindowManifest.sha256(Data(lines.joined(separator: "\n").utf8))
    }
    public init(manifest: VocabularyWireStagedManifest, upload: VocabularyWireStagedUpload) throws {
        guard let reason = Reason(rawValue: manifest.state.rawValue) else { throw VocabularyWireStagedError.invalidManifest }
        try manifest.validate(for: upload, now: Date())
        scope = upload.batch.scope; groupID = upload.batch.request.groupID; self.reason = reason
        descriptorSHA256 = upload.descriptorSHA256; bodySHA256 = upload.bodySHA256
        bodyByteCount = upload.body.count; memberCount = upload.batch.request.members.count
    }
    public init(from decoder: any Decoder) throws {
        var f = try VocabularyWireFields(VocabularyWireJSON(from: decoder))
        guard try f.integer("protocolVersion") == 1 else { throw VocabularyWireStagedError.invalidManifest }
        scope = .init(ownerUserID: try f.string("ownerUserId"), workspaceID: try f.uuid("workspaceId"),
            notebookID: try f.uuid("notebookId"), replicaID: try f.uuid("replicaId"))
        groupID = try f.uuid("groupId")
        guard let reason = Reason(rawValue: try f.string("reason")) else { throw VocabularyWireStagedError.invalidManifest }
        self.reason = reason; descriptorSHA256 = try f.string("descriptorSha256"); bodySHA256 = try f.string("bodySha256")
        bodyByteCount = try f.integer("bodyByteCount", maximum: VocabularyWireStagedLimits.maximumBodyBytes, minimum: 1)
        memberCount = try f.integer("memberCount", maximum: VocabularyWireStagedLimits.maximumMembers, minimum: 1)
        let digest = try f.string("closureSha256"); try f.finish()
        guard !scope.ownerUserID.utf8.isEmpty, [descriptorSHA256, bodySHA256, digest].allSatisfy(VocabularyWireWindowManifest.isSHA256),
              digest == closureSHA256 else { throw VocabularyWireStagedError.invalidManifest }
    }
    public func validate(for upload: VocabularyWireStagedUpload) throws {
        guard scope == upload.batch.scope, groupID == upload.batch.request.groupID, descriptorSHA256 == upload.descriptorSHA256,
              bodySHA256 == upload.bodySHA256, bodyByteCount == upload.body.count, memberCount == upload.batch.request.members.count else {
            throw VocabularyWireStagedError.invalidManifest
        }
    }
    public func encode(to encoder: any Encoder) throws {
        try VocabularyWireJSON.object(["protocolVersion": .number(1), "ownerUserId": .string(scope.ownerUserID), "workspaceId": .uuid(scope.workspaceID),
            "notebookId": .uuid(scope.notebookID), "replicaId": .uuid(scope.replicaID), "groupId": .uuid(groupID), "reason": .string(reason.rawValue),
            "descriptorSha256": .string(descriptorSHA256), "bodySha256": .string(bodySHA256), "bodyByteCount": .number(Double(bodyByteCount)),
            "memberCount": .number(Double(memberCount)), "closureSha256": .string(closureSHA256)]).encode(to: encoder)
    }
}
