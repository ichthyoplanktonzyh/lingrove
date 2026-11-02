import Foundation
import LingroveNotebook
import LingroveNotebookSync

/// A bounded presentation value, never a corpus payload or transport error.
/// The binding lets the store discard a result from an abandoned account.
public nonisolated struct NotebookSyncReport: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case synchronized, pending, unavailable, offline, conflict, rejected, cancelled, failed, ownershipRequired
    }
    public let binding: NotebookBinding
    public let notebookID: UUID
    public let revision: UInt64
    public let status: Status
    public let reviewRevision: Int64
    public let reviewStatus: Status?
    public init(binding: NotebookBinding, notebookID: UUID, revision: UInt64, status: Status,
         reviewRevision: Int64 = 0, reviewStatus: Status? = nil) {
        self.binding = binding; self.notebookID = notebookID; self.revision = revision; self.status = status
        self.reviewRevision = reviewRevision; self.reviewStatus = reviewStatus
    }

    public func hash(into hasher: inout Hasher) {
        // Scope equality uses literal owner bytes rather than String's Unicode
        // equivalence. Hash the same identity without broadening the wire API.
        hasher.combine(binding.generation)
        hasher.combine(Data(binding.scope.ownerUserID.utf8))
        hasher.combine(binding.scope.workspaceID); hasher.combine(binding.scope.notebookID); hasher.combine(binding.scope.replicaID)
        hasher.combine(notebookID); hasher.combine(revision); hasher.combine(status); hasher.combine(reviewRevision); hasher.combine(reviewStatus)
    }
}

/// The host owns this process-lifetime single-flight adapter and explicitly authorizes each pass. Its short-lived retry gate prevents
/// polling from manufacturing new rejected groups for unchanged local intent.
/// Frozen requests/outcomes remain durable in SQLite; this gate never retires
/// them or releases the independent managed Card/review lane.
@MainActor
public final class NotebookSyncCoordinator {
    private struct RetryGate {
        let report: NotebookSyncReport
        let endpoint: String
        let until: Date?
    }
    private let storage: any NotebookStorage
    private let reviewStorage: any NotebookReviewStorage
    private let runner: NotebookNetworkRunner
    private let transport: NotebookHTTPTransport
    private var gate: RetryGate?
    private var retryGeneration = UUID()
    private var explicitRetryAuthorization: NotebookRetryAuthorization?
    private var flight: (id: UUID, account: NotebookAccount, task: Task<NotebookSyncReport, Error>)?

    public init(storage: any NotebookStorage, mediaStorage: any NotebookMediaStorage,
                reviewStorage: any NotebookReviewStorage, transport: NotebookHTTPTransport = .init(),
                mediaTransport: NotebookMediaTransport = .init(), transfers: NotebookMediaTransfers = .init()) {
        self.storage = storage; self.reviewStorage = reviewStorage; self.transport = transport
        runner = .init(storage: storage, mediaStorage: mediaStorage, transport: transport,
                       mediaTransport: mediaTransport, transfers: transfers)
    }

    /// The host captures exact durable retry authorization (and authorizes its known media queue)
    /// before this call. A click never resumes a newer cancellation or invents an ownership choice.
    public func requestRetry(_ authorization: NotebookRetryAuthorization? = nil) {
        retryGeneration = UUID(); gate = nil; explicitRetryAuthorization = authorization
    }

    /// Account lifecycle owns cancellation. A cancelled individual waiter cannot tear down another
    /// consumer's pass; logout/switch calls this method and advances the repository generation.
    public func cancel() {
        flight?.task.cancel(); flight = nil
        retryGeneration = UUID(); gate = nil; explicitRetryAuthorization = nil
    }

    public func synchronize(_ account: NotebookAccount) async throws -> NotebookSyncReport {
        try Task.checkCancellation()
        if let flight {
            guard flight.account.matches(account) else { throw NotebookStorageError.bindingChanged }
            let result = try await flight.task.value
            try Task.checkCancellation()
            return result
        }
        let id = UUID()
        let task = Task { try await synchronizeOnce(account) }
        flight = (id, account, task)
        defer { if flight?.id == id { flight = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    private func synchronizeOnce(_ account: NotebookAccount) async throws -> NotebookSyncReport {
        try Task.checkCancellation()
        let attemptGeneration = retryGeneration
        guard let workspace = UUID(uuidString: account.workspaceId) else { throw CancellationError() }
        let ticket = try storage.capture(scope: .init(ownerUserID: account.userId,
            workspaceID: workspace, notebookID: UUID(), replicaID: UUID()))
        let initial = try await storage.initial(ticket)
        try storage.validate(ticket)
        if let gate, gate.endpoint == account.apiBaseUrl,
           gate.report.binding.generation == ticket.generation,
           gate.report.binding.scope.workspaceID == workspace,
           gate.report.notebookID == initial.notebookID, gate.report.revision == initial.revision,
           gate.until.map({ $0 > Date() }) ?? true { return gate.report }
        gate = nil
        let retry = explicitRetryAuthorization.flatMap { authorization -> NotebookRetryAuthorization? in
            let captured = authorization.binding
            return captured.generation == ticket.generation && captured.scope.workspaceID == workspace
                && captured.scope.ownerUserID.utf8.elementsEqual(account.userId.utf8) ? authorization : nil
        }
        // Consume one matching click per attempt. Once authorization commits, its
        // authorization is durable; a later failure cannot reauthorize a NEW
        // cancellation on a future background run. ABA never transfers a click.
        if retry != nil { explicitRetryAuthorization = nil }
        do {
            let result = try await runner.synchronize(account, retryAuthorization: retry)
            try storage.validate(ticket)
            let state = try await storage.state(result.binding)
            try storage.validate(ticket)
            let review = state.pendingCount == 0 && !state.rejected && !state.uploadCancelled
                ? try await synchronizeReview(account, binding: result.binding)
                : (revision: Int64(0), status: NotebookSyncReport.Status.pending)
            try storage.validate(ticket)
            let local = state
            let status: NotebookSyncReport.Status
            if case let .rejected(rejection)? = result.outcome {
                status = rejection.reason == .entityConflict ? .conflict : .rejected
            } else if state.rejected { status = .rejected }
            else if state.uploadCancelled { status = .cancelled }
            else if result.cleanupPending || state.pendingCount > 0 {
                status = .pending
            } else { status = .synchronized }
            let report = NotebookSyncReport(binding: result.binding, notebookID: local.notebookID, revision: local.revision, status: status, reviewRevision: review.revision, reviewStatus: review.status)
            if attemptGeneration == retryGeneration, (status == .rejected || status == .conflict) {
                gate = .init(report: report, endpoint: account.apiBaseUrl, until: nil)
            }
            return report
        } catch {
            if isCloudCancellation(error) { throw error }
            // No old completion may install a retry gate or UI report after
            // account/workspace ABA. The cancellation remains visible upstream.
            do { try storage.validate(ticket) }
            catch { throw CancellationError() }
            try Task.checkCancellation()
            if case let NotebookNetworkError.http(status, _) = error,
               status == 401 || status == 410 {
                // The app-owned account service refreshes or retires credentials; a network
                // package never invents a replacement identity or hides authentication failure.
                throw error
            }
            let status: NotebookSyncReport.Status
            let delay: TimeInterval?
            if error as? NotebookStorageError == .ownershipRequired { status = .ownershipRequired; delay = nil }
            else if error is VocabularyWireRebaseError { status = .conflict; delay = nil }
            else if error as? NotebookMediaError == .incomplete(.cancelled) { status = .cancelled; delay = 30 }
            else if error as? NotebookMediaError == .incomplete(.missing)
                    || error as? NotebookMediaError == .incomplete(.queued)
                    || error as? NotebookMediaError == .busy { status = .pending; delay = 10 }
            else if case NotebookNetworkError.http(404, "NOTEBOOK_MEDIA_MISSING") = error { status = .pending; delay = 10 }
            else if let network = error as? NotebookNetworkError,
                    case .http(404, _) = network { status = .unavailable; delay = 300 }
            else if case let NotebookNetworkError.http(statusCode, code) = error, statusCode == 503,
                    ["NOTEBOOK_SYNC_UNAVAILABLE","NOTEBOOK_STAGED_SYNC_UNAVAILABLE"].contains(code ?? "") { status = .unavailable; delay = 300 }
            else if error is VocabularyWireError || error as? NotebookNetworkError == .stagedUnavailable
                    || error as? VocabularyWireUploadError == .requestTooLarge { status = .unavailable; delay = 300 }
            else if error as? NotebookStorageError == .cancelledUpload { status = .cancelled; delay = 30 }
            else if let network = error as? URLError,
                    [.notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost].contains(network.code) {
                status = .offline; delay = 30
            } else { status = .failed; delay = 30 }
            let local = try await storage.initial(ticket)
            try storage.validate(ticket)
            let report = NotebookSyncReport(binding: ticket, notebookID: local.notebookID, revision: local.revision, status: status)
            // An explicit retry during this await belongs to the NEXT pass in
            // CloudSessionRuntime's loop. This old failure must not close that
            // new attempt by reinstalling the gate the user just cleared.
            if attemptGeneration == retryGeneration, status != .cancelled {
                gate = .init(report: report, endpoint: account.apiBaseUrl, until: delay.map { Date().addingTimeInterval($0) })
            }
            return report
        }
    }
    /// Corpus/media have already committed before this independent lane runs.
    /// A private review endpoint may be unavailable or fail after a page: keep
    /// the actual corpus revision and durable review cursor visible, retaining
    /// held work for retry. Authentication and account cancellation still reach
    /// the existing session recovery boundary.
    private func synchronizeReview(_ account: NotebookAccount, binding: NotebookBinding) async throws
        -> (revision: Int64, status: NotebookSyncReport.Status) {
        do {
            let result = try await NotebookReviewNetworkRunner(storage: reviewStorage, transport: transport, validate: { try self.storage.validate($0) }).synchronize(account, binding: binding)
            return (result.revision, result.pending ? .pending : .synchronized)
        } catch {
            if isCloudCancellation(error) { throw error }
            try storage.validate(binding)
            try Task.checkCancellation()
            if case let NotebookNetworkError.http(status, _) = error, status == 401 || status == 410 { throw error }
            let revision = try await reviewStorage.revision(binding)
            try storage.validate(binding)
            let status: NotebookSyncReport.Status
            if case let NotebookNetworkError.http(code, reason) = error,
               code == 404 || (code == 503 && reason == "NOTEBOOK_REVIEW_UNAVAILABLE") { status = .unavailable }
            else if let network = error as? URLError,
                    [.notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost].contains(network.code) { status = .offline }
            else { status = .failed }
            return (revision, status)
        }
    }

}
