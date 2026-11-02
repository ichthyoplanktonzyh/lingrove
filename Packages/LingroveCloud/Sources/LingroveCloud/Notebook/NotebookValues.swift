import CryptoKit
import Foundation
import LingroveNotebookSync

/// Explicit host authorization for one network pass. The owner comes from trusted `/me`, never a
/// JWT subject; constructing this value neither adopts local data nor starts a request. Automation
/// flags are host inputs to the unchanged connect wire contract, with no Bundle/environment guess.
public nonisolated struct NotebookAccount: Sendable {
    public let userId: String
    public let workspaceId: String
    public let apiBaseUrl: String
    public let authorizationHeaderValue: String
    public let isAutomation: Bool
    public let isTestDistribution: Bool
    public init(userID: String, workspaceID: UUID, apiBaseURL: String, authorizationHeaderValue: String,
                isAutomation: Bool, isTestDistribution: Bool) {
        userId = userID; workspaceId = workspaceID.uuidString.lowercased(); apiBaseUrl = apiBaseURL
        self.authorizationHeaderValue = authorizationHeaderValue
        self.isAutomation = isAutomation; self.isTestDistribution = isTestDistribution
    }
    func matches(_ other: Self) -> Bool {
        userId.utf8.elementsEqual(other.userId.utf8) && workspaceId == other.workspaceId
            && apiBaseUrl == other.apiBaseUrl
    }
}

/// A durable host generation plus exact NotebookSync scope. The storage adapter must check this
/// again inside every transaction, since an asynchronous preflight alone cannot prevent ABA writes.
public nonisolated struct NotebookBinding: Equatable, Sendable {
    public let scope: VocabularyWireWindowScope
    public let generation: String
    public init(scope: VocabularyWireWindowScope, generation: String) { self.scope = scope; self.generation = generation }
}

/// Network state needs only revision metadata. The host repository retains document and journal
/// coverage; a runner never manufactures a replacement corpus or acknowledges unrelated rows.
public nonisolated struct NotebookLocalState: Sendable {
    public let notebookID: UUID
    public let revision: UInt64
    public let pendingCount: Int
    public let uploadCancelled: Bool
    public let rejected: Bool
    public init(notebookID: UUID, revision: UInt64, pendingCount: Int, uploadCancelled: Bool, rejected: Bool) {
        self.notebookID = notebookID; self.revision = revision; self.pendingCount = pendingCount
        self.uploadCancelled = uploadCancelled; self.rejected = rejected
    }
}

/// Frozen public request bytes borrowed from storage. SQL coverage remains private to the host,
/// addressed by frozenSHA256. The host supplies the planner-validated batch with its exact frozen
/// bytes; transport bounds them without re-encoding a large body. Receipt/confirmation ports
/// must retain the same identity for exact ACK retirement.
public nonisolated struct NotebookPendingUpload: Sendable {
    public let batch: VocabularyWireUploadBatch
    public let body: Data
    public let outcome: VocabularyWireGroupOutcome?
    public let cancelRequested: Bool
    public let frozenSHA256: String
    public let stagedUpload: VocabularyWireStagedUpload?
    public let confirmationManifest: VocabularyWireConfirmationManifest?
    public let receivedConfirmationOrdinals: [Int]
    public let stagedClosure: VocabularyWireStagedClosure?
    public var bodySHA256: String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }
    public init(batch: VocabularyWireUploadBatch, body: Data, outcome: VocabularyWireGroupOutcome?, cancelRequested: Bool,
                frozenSHA256: String, stagedUpload: VocabularyWireStagedUpload?,
                confirmationManifest: VocabularyWireConfirmationManifest?, receivedConfirmationOrdinals: [Int],
                stagedClosure: VocabularyWireStagedClosure?) throws {
        guard !body.isEmpty, body.count <= (batch.transport == .staged ? VocabularyWireStagedLimits.maximumBodyBytes : 2 * 1024 * 1024),
              frozenSHA256.utf8.count == 64, frozenSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (batch.transport == .staged) == (stagedUpload != nil) else { throw NotebookStorageError.corruptBatch }
        if let outcome { try outcome.validate(for: batch) }
        if let stagedUpload { guard stagedUpload.body == body else { throw NotebookStorageError.corruptBatch } }
        self.batch = batch; self.body = body; self.outcome = outcome; self.cancelRequested = cancelRequested
        self.frozenSHA256 = frozenSHA256; self.stagedUpload = stagedUpload
        self.confirmationManifest = confirmationManifest; self.receivedConfirmationOrdinals = receivedConfirmationOrdinals
        self.stagedClosure = stagedClosure
    }
}

/// A small control read between chunks avoids reparsing a potentially large immutable body.
public nonisolated struct NotebookUploadControl: Sendable {
    public let cancelRequested: Bool
    public let hasSettlement: Bool
    public init(cancelRequested: Bool, hasSettlement: Bool) { self.cancelRequested = cancelRequested; self.hasSettlement = hasSettlement }
}

/// An explicit Retry click authorizes only previously captured cancellation revisions. Newer
/// cancellations and a different account generation must remain blocked by the storage adapter.
public nonisolated struct NotebookRetryAuthorization: Sendable {
    public struct Pending: Sendable {
        public let groupID: UUID
        public let frozenSHA256: String
        public let cancelRevision: Int64
        public init(groupID: UUID, frozenSHA256: String, cancelRevision: Int64) {
            self.groupID = groupID; self.frozenSHA256 = frozenSHA256; self.cancelRevision = cancelRevision
        }
    }
    public let binding: NotebookBinding
    public let completedGroups: [UUID]
    public let pending: Pending?
    public let rejectionID: String?
    public init(binding: NotebookBinding, completedGroups: [UUID], pending: Pending?, rejectionID: String?) {
        self.binding = binding; self.completedGroups = completedGroups; self.pending = pending; self.rejectionID = rejectionID
    }
}

/// Storage adapters map their closed local errors, retaining actionable admission without SQL.
public nonisolated enum NotebookStorageError: Error, Equatable, Sendable {
    case ownershipRequired, bindingChanged, cancelledUpload, rejectedIntent, awaitingReceipt, corruptBatch
}
public nonisolated enum NotebookNetworkError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidReply, replyTooLarge, identityMismatch, stagedUnavailable
    case http(status: Int, code: String?)
}

/// Successful corpus settlement and cleanup debt remain distinct. A cleanup retry must not undo
/// committed cursors, fabricate a failed corpus report, or create another frozen group identity.
public nonisolated struct NotebookNetworkResult: Sendable {
    public let binding: NotebookBinding
    public let state: NotebookLocalState
    public let outcome: VocabularyWireGroupOutcome?
    public let cleanupPending: Bool
    public let uploadCancelled: Bool
    public init(binding: NotebookBinding, state: NotebookLocalState, outcome: VocabularyWireGroupOutcome?, cleanupPending: Bool,
                uploadCancelled: Bool = false) {
        self.binding = binding; self.state = state; self.outcome = outcome; self.cleanupPending = cleanupPending
        self.uploadCancelled = uploadCancelled
    }
}

/// Uniform cancellation classification includes URLSession cancellation but carries no body.
public nonisolated func isCloudCancellation(_ error: any Error) -> Bool {
    error is CancellationError || error as? AccountIssue == .cancelled || (error as? URLError)?.code == .cancelled
}
