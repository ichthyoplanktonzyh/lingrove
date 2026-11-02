import Foundation
import LingroveNotebook
import LingroveNotebookSync

/// Local operational state is separate from corpus acknowledgement. Ready means
/// validated bytes and a workspace mapping, never just received JSON metadata.
public nonisolated enum LingroveNotebookMediaState: String, Codable, Sendable {
    case queued, transferring, missing, failed, cancelled, ready
}
public nonisolated enum LingroveNotebookMediaDirection: String, Codable, Sendable { case upload, download }
public nonisolated enum LingroveNotebookMediaError: Error, Equatable {
    case incomplete(LingroveNotebookMediaState), staleAttempt, invalidDescriptor, busy
}
public nonisolated struct LingroveNotebookMediaJob: Sendable, Identifiable {
    public let id: String
    public let reference: VocabularyImageReference
    public let direction: LingroveNotebookMediaDirection
    public let state: LingroveNotebookMediaState
    public let remoteAssetID: UUID?
    public let attempts: Int
    public let revision: Int64
    public let attemptID: String?

    public init(id: String, reference: VocabularyImageReference, direction: LingroveNotebookMediaDirection, state: LingroveNotebookMediaState, remoteAssetID: UUID?, attempts: Int, revision: Int64, attemptID: String?) {
        self.id = id
        self.reference = reference
        self.direction = direction
        self.state = state
        self.remoteAssetID = remoteAssetID
        self.attempts = attempts
        self.revision = revision
        self.attemptID = attemptID
    }
}
public nonisolated struct LingroveNotebookMediaDescriptor: Codable, Sendable {
    public let protocolVersion: Int
    public let notebookId: UUID
    public let replicaId: UUID
    public let image: VocabularyImageReference
    public let ownerUserId: String
    public let workspaceId: UUID
    public let mediaAssetId: UUID
    public let state: String

    public func validate(_ reference: VocabularyImageReference, binding: LingroveNotebookWindowBinding) throws {
        guard protocolVersion == 1, notebookId == binding.scope.notebookID, replicaId == binding.scope.replicaID,
              ownerUserId.utf8.elementsEqual(binding.scope.ownerUserID.utf8), workspaceId == binding.scope.workspaceID,
              image == reference, ["ready", "missing"].contains(state) else { throw LingroveNotebookMediaError.invalidDescriptor }
    }

    public init(protocolVersion: Int, notebookId: UUID, replicaId: UUID, image: VocabularyImageReference, ownerUserId: String, workspaceId: UUID, mediaAssetId: UUID, state: String) {
        self.protocolVersion = protocolVersion
        self.notebookId = notebookId
        self.replicaId = replicaId
        self.image = image
        self.ownerUserId = ownerUserId
        self.workspaceId = workspaceId
        self.mediaAssetId = mediaAssetId
        self.state = state
    }
}
