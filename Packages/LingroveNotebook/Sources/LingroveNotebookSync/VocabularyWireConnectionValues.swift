import Foundation

/// Negotiation precedes any corpus body. These fixed requirements describe the
/// lane this version can safely consume; unsupported servers remain unavailable
/// rather than falling through to legacy Card synchronization.
public nonisolated struct VocabularyWireCapabilities: Decodable, Sendable {
    public let stagedUploads: VocabularyWireStagedCapabilities?
    public init(from decoder: any Decoder) throws {
        guard case var .object(values) = try VocabularyWireJSON(from: decoder) else { throw VocabularyWireError.invalidRecord }
        // Only this named extension is optional. All other unknown fields still
        // fail closed, and an older response without it keeps direct transport.
        stagedUploads = try values.removeValue(forKey: "stagedUploads").map(VocabularyWireStagedCapabilities.init)
        var f = VocabularyWireFields(values)
        guard try f.string("lane") == "lingrove.corpus", try f.integer("protocolVersion") == 1,
              try f.integer("documentVersion") == 8, try f.bool("terminalGroups"), try f.bool("readWindows"), try f.bool("readOnlyCatalog"),
              try f.integer("maximumGroupBytes") == 2 * 1024 * 1024, try f.integer("maximumGroupMembers") == 10_000,
              try f.integer("pageBytes") == 256 * 1024, try f.integer("windowLifetimeMilliseconds", minimum: 1) > 0 else {
            throw VocabularyWireError.invalidRecord
        }
        let kinds = try f.array("entityTypes").map(VocabularyWireFields.string)
        guard kinds.count == VocabularyWireEntityKind.allCases.count,
              Set(kinds) == Set(VocabularyWireEntityKind.allCases.map(\.rawValue)) else { throw VocabularyWireError.invalidRecord }
        try f.finish()
    }
}

/// Negotiated admission, not a resource guarantee at the declaration ceiling.
/// Chunk framing, permanent closures and complete paged confirmations are one
/// protocol: a server advertising only part of that contract cannot be used.
public nonisolated struct VocabularyWireStagedCapabilities: Sendable {
    public let maximumBodyBytes: Int
    public let maximumMembers: Int
    init(_ json: VocabularyWireJSON) throws {
        var f = try VocabularyWireFields(json)
        guard try f.integer("protocolVersion") == 1, try f.bool("permanentClosures"), try f.bool("pagedConfirmations"),
              try f.integer("chunkBytes") == VocabularyWireStagedLimits.chunkBytes,
              try f.integer("confirmationMembersPerPage") == VocabularyWireStagedLimits.confirmationMembersPerPage,
              try f.integer("lifetimeMilliseconds") == 900_000 else { throw VocabularyWireError.invalidRecord }
        maximumBodyBytes = try f.integer("maximumBodyBytes", maximum: VocabularyWireStagedLimits.maximumBodyBytes, minimum: 1)
        maximumMembers = try f.integer("maximumMembers", maximum: VocabularyWireStagedLimits.maximumMembers, minimum: 1)
        try f.finish()
    }
    public func validate(bodyBytes: Int, members: Int) throws {
        guard bodyBytes > 0, bodyBytes <= maximumBodyBytes, members > 0, members <= maximumMembers else {
            throw VocabularyWireUploadError.requestTooLarge
        }
    }
}

/// The authenticated server supplies the canonical book and installation's
/// replica. The host matches account/workspace against its captured generation;
/// this response alone is never permission to replace or rebind local content.
public nonisolated struct VocabularyWireConnection: Decodable, Sendable {
    public let ownerUserID: String
    public let workspaceID: UUID
    public let notebookID: UUID
    public let replicaID: UUID
    public let committedSequence: VocabularyWireSequence
    public init(from decoder: any Decoder) throws {
        var f = try VocabularyWireFields(VocabularyWireJSON(from: decoder))
        guard try f.integer("protocolVersion") == 1 else { throw VocabularyWireError.invalidRecord }
        ownerUserID = try f.string("ownerUserId"); workspaceID = try f.uuid("workspaceId")
        notebookID = try f.uuid("notebookId"); replicaID = try f.uuid("replicaId")
        committedSequence = try .init(f.string("committedSequence"))
        guard !ownerUserID.isEmpty else { throw VocabularyWireError.invalidRecord }
        try f.finish()
    }
}
