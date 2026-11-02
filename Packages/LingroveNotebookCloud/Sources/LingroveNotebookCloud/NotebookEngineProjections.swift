import Foundation
import LingroveCloud
import LingroveNotebookEngine

// These projections preserve identities and bytes only. SQL coverage, PNG validation, scope
// authorization and canonical review decoding remain in the engine, never in a network value.
extension NotebookBinding {
    nonisolated var engineBinding: LingroveNotebookWindowBinding { .init(scope: scope, generation: generation) }
    nonisolated var workspace: String { scope.workspaceID.uuidString.lowercased() }
}
extension LingroveNotebookWindowBinding {
    nonisolated var networkBinding: NotebookBinding { .init(scope: scope, generation: generation) }
}
extension LingroveNotebookSyncState {
    nonisolated var networkState: NotebookLocalState {
        .init(notebookID: snapshot.notebookId, revision: snapshot.revision, pendingCount: pendingCount,
              uploadCancelled: uploadCancelled, rejected: rejected)
    }
}
extension LingroveNotebookPendingUpload {
    nonisolated var networkPending: NotebookPendingUpload {
        get throws {
            try .init(batch: batch, body: body, outcome: outcome, cancelRequested: cancelRequested,
                frozenSHA256: frozenSHA256, stagedUpload: stagedUpload, confirmationManifest: confirmationManifest,
                receivedConfirmationOrdinals: receivedConfirmationOrdinals, stagedClosure: stagedClosure)
        }
    }
}
extension NotebookRetryAuthorization {
    nonisolated var engineAuthorization: LingroveNotebookRetryAuthorization {
        .init(binding: binding.engineBinding, completedGroups: completedGroups,
            pending: pending.map { .init(groupID: $0.groupID, frozenSHA256: $0.frozenSHA256, cancelRevision: $0.cancelRevision) },
            rejectionID: rejectionID)
    }
}
extension NotebookMediaDirection {
    nonisolated var engineDirection: LingroveNotebookMediaDirection {
        switch self {
        case .upload: .upload
        case .download: .download
        }
    }
}
extension LingroveNotebookMediaDirection {
    nonisolated var networkDirection: NotebookMediaDirection {
        switch self {
        case .upload: .upload
        case .download: .download
        }
    }
}
extension NotebookMediaState {
    nonisolated var engineState: LingroveNotebookMediaState {
        switch self {
        case .queued: .queued
        case .transferring: .transferring
        case .missing: .missing
        case .failed: .failed
        case .cancelled: .cancelled
        case .ready: .ready
        }
    }
}
extension LingroveNotebookMediaState {
    nonisolated var networkState: NotebookMediaState {
        switch self {
        case .queued: .queued
        case .transferring: .transferring
        case .missing: .missing
        case .failed: .failed
        case .cancelled: .cancelled
        case .ready: .ready
        }
    }
}
extension NotebookMediaJob {
    nonisolated var engineJob: LingroveNotebookMediaJob {
        .init(id: id, reference: reference, direction: direction.engineDirection, state: state.engineState,
              remoteAssetID: remoteAssetID, attempts: attempts, revision: revision, attemptID: attemptID)
    }
}
extension LingroveNotebookMediaJob {
    nonisolated var networkJob: NotebookMediaJob {
        .init(id: id, reference: reference, direction: direction.networkDirection, state: state.networkState,
              remoteAssetID: remoteAssetID, attempts: attempts, revision: revision, attemptID: attemptID)
    }
}

/// Closed errors retain actionable network classifications without leaking SQL messages into
/// UI copy. Unknown failures keep their type for diagnostics; the coordinator publishes safe states.
nonisolated func networkStorageFailure(_ error: any Error) -> any Error {
    switch error {
    case is LingroveNotebookAccountError: return NotebookStorageError.ownershipRequired
    case LingroveNotebookWindowStoreError.bindingChanged: return NotebookStorageError.bindingChanged
    case LingroveNotebookUploadStoreError.cancelledUpload: return NotebookStorageError.cancelledUpload
    case LingroveNotebookUploadStoreError.rejectedIntent: return NotebookStorageError.rejectedIntent
    case LingroveNotebookUploadStoreError.awaitingReceipt: return NotebookStorageError.awaitingReceipt
    case LingroveNotebookUploadStoreError.corruptBatch: return NotebookStorageError.corruptBatch
    case let media as LingroveNotebookMediaError: return networkMediaFailure(media)
    default: return error
    }
}
private nonisolated func networkMediaFailure(_ error: LingroveNotebookMediaError) -> NotebookMediaError {
    switch error {
    case .busy: .busy
    case .staleAttempt: .staleAttempt
    case .invalidDescriptor: .invalidDescriptor
    case .incomplete(let state): .incomplete(state.networkState)
    }
}
nonisolated func mapFailure<T>(_ work: () throws -> T) throws -> T {
    do { return try work() } catch { throw networkStorageFailure(error) }
}
