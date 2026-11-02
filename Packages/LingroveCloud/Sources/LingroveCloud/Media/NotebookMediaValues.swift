import Foundation
import LingroveNotebook
import LingroveNotebookSync

/// Local operational state is separate from corpus acknowledgement. Ready means
/// validated bytes and a workspace mapping, never just received JSON metadata.
public nonisolated enum NotebookMediaState: String, Codable, Sendable {
    case queued, transferring, missing, failed, cancelled, ready
}
public nonisolated enum NotebookMediaDirection: String, Codable, Sendable { case upload, download }
public nonisolated enum NotebookMediaError: Error, Equatable {
    case incomplete(NotebookMediaState), staleAttempt, invalidDescriptor, busy
}
public nonisolated struct NotebookMediaJob: Sendable, Identifiable {
    public init(id: String, reference: VocabularyImageReference, direction: NotebookMediaDirection,
                state: NotebookMediaState, remoteAssetID: UUID?, attempts: Int, revision: Int64, attemptID: String?) {
        self.id = id; self.reference = reference; self.direction = direction; self.state = state
        self.remoteAssetID = remoteAssetID; self.attempts = attempts; self.revision = revision; self.attemptID = attemptID
    }

    public let id: String
    public let reference: VocabularyImageReference
    public let direction: NotebookMediaDirection
    public let state: NotebookMediaState
    public let remoteAssetID: UUID?
    public let attempts: Int
    public let revision: Int64
    public let attemptID: String?
}
public nonisolated struct NotebookMediaDescriptor: Codable, Sendable {
    public let protocolVersion: Int
    public let notebookId: UUID
    public let replicaId: UUID
    public let image: VocabularyImageReference
    public let ownerUserId: String
    public let workspaceId: UUID
    public let mediaAssetId: UUID
    public let state: String

    public func validate(_ reference: VocabularyImageReference, binding: NotebookBinding) throws {
        guard protocolVersion == 1, notebookId == binding.scope.notebookID, replicaId == binding.scope.replicaID,
              ownerUserId.utf8.elementsEqual(binding.scope.ownerUserID.utf8), workspaceId == binding.scope.workspaceID,
              image == reference, ["ready", "missing"].contains(state) else { throw NotebookMediaError.invalidDescriptor }
    }
}
