import Foundation

/// One consistent storage projection for both native hosts and their network adapter. Flags are
/// read with the snapshot, rather than guessing upload state from a separately read UI revision.
public struct LingroveNotebookSyncState: Sendable {
    public let snapshot: LingroveNotebookSnapshot
    public let pendingCount: Int
    public let uploadCancelled: Bool
    public let rejected: Bool
}

extension LingroveNotebookEngine {
    public func notebookSyncState(_ binding: LingroveNotebookWindowBinding) throws -> LingroveNotebookSyncState {
        try core.inReadTransaction {
            try lingroveNotebookWindowStore.checkBindingInTransaction(binding)
            let snapshot = try lingroveNotebookStore.readSnapshot(workspaceId: binding.scope.workspaceID.uuidString.lowercased())
            let revision = try core.scalarInt(sql: """
                SELECT COALESCE(MAX(revision),0) FROM notebook_pending_transactions
                WHERE workspace_id=? AND notebook_id=? AND has_public_change=1
                """, values: [.text(snapshot.workspaceId), .text(snapshot.notebookId.uuidString)])
            let cancelled: Bool
            do {
                try LingroveNotebookUploadClosureStore(core: core).checkRetryInTransaction(
                    binding: binding, localNotebookID: snapshot.notebookId, journalRevision: Int64(revision))
                cancelled = false
            } catch LingroveNotebookUploadStoreError.cancelledUpload { cancelled = true }
            let rejected: Bool
            do {
                try LingroveNotebookConflictStore(core: core).checkRejectionInTransaction(binding: binding)
                rejected = false
            } catch LingroveNotebookUploadStoreError.rejectedIntent { rejected = true }
            return .init(snapshot: snapshot, pendingCount: try lingroveNotebookStore.pendingCount(workspaceId: snapshot.workspaceId),
                         uploadCancelled: cancelled, rejected: rejected)
        }
    }
}
