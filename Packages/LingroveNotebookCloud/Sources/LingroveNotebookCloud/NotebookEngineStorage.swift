import Foundation
import LingroveCloud
import LingroveNotebook
import LingroveNotebookEngine
import LingroveNotebookSync

/// The one bridge between portable network ports and the authoritative SQLite engine. The app
/// owns it beside its primary engine and coordinator. Synchronous lifetime checks use that engine;
/// asynchronous stages open a temporary connection to the same file, exactly like mobile SyncIO.
/// Each stage closes before returning immutable values; no SQLite transaction spans an HTTP await.
@MainActor
public final class NotebookEngineStorage: NotebookStorage, NotebookMediaStorage, NotebookReviewStorage {
    public let engine: LingroveNotebookEngine
    private let databaseURL: URL
    private let mediaURL: URL

    public init(engine: LingroveNotebookEngine) {
        self.engine = engine
        databaseURL = engine.databaseURL
        mediaURL = engine.core.mediaDirectoryURL
    }

    public func installation(for account: NotebookAccount) throws -> UUID {
        // The storage contract only borrows trusted identity/endpoint. It never saves this
        // transient authorization value or sends it anywhere from the SQLite layer.
        try mapFailure {
            try LingroveNotebookAccountStore(core: engine.core).installation(for: .init(
                userId: account.userId, workspaceId: account.workspaceId, email: nil, configurationMode: .custom,
                apiBaseUrl: account.apiBaseUrl, authorization: account.isGuest
                    ? .guest("storage-metadata-only") : .bearer("storage-metadata-only")))
        }
    }

    public func capture(scope: VocabularyWireWindowScope) throws -> NotebookBinding {
        try mapFailure { try engine.captureLingroveNotebookWindowBinding(scope: scope).networkBinding }
    }

    public func validate(_ binding: NotebookBinding) throws {
        try Task.checkCancellation()
        try mapFailure { try engine.validateLingroveNotebookWindowBinding(binding.engineBinding) }
    }

    /// A Retry click captures only existing durable cancellation revisions. Keeping this next to
    /// the storage adapter lets both hosts share authorization without teaching a view about SQL.
    public func captureRetry(resumeCancelledUploads: Bool) throws -> NotebookRetryAuthorization? {
        try mapFailure {
            let settings = try engine.workspaceSettingsStore.loadCloudSettings()
            guard let owner = settings.linkedUserId, let text = settings.linkedWorkspaceId,
                  let workspace = UUID(uuidString: text) else { return nil }
            let ticket = try engine.captureLingroveNotebookWindowBinding(scope: .init(ownerUserID: owner,
                workspaceID: workspace, notebookID: UUID(), replicaID: UUID()))
            try LingroveNotebookMediaQueueStore(core: engine.core).retryKnown(ticket, resumeCancelled: resumeCancelledUploads)
            guard let value = try LingroveNotebookRetryStore(core: engine.core).captureKnown(ticket) else { return nil }
            return NotebookRetryAuthorization(binding: value.binding.networkBinding,
                completedGroups: resumeCancelledUploads ? value.completedGroups : [],
                pending: resumeCancelledUploads ? value.pending.map { .init(groupID: $0.groupID,
                    frozenSHA256: $0.frozenSHA256, cancelRevision: $0.cancelRevision) } : nil,
                rejectionID: resumeCancelledUploads ? value.rejectionID : nil)
        }
    }

    public func initial(_ binding: NotebookBinding) async throws -> NotebookLocalState {
        try await stage(binding) { db in
            _ = try db.lingroveNotebookStore.load(workspaceId: binding.workspace, requireActiveWorkspace: true,
                                                binding: binding.engineBinding)
            return try db.notebookSyncState(binding.engineBinding).networkState
        }
    }

    public func state(_ binding: NotebookBinding) async throws -> NotebookLocalState {
        try await stage(binding) { try $0.notebookSyncState(binding.engineBinding).networkState }
    }

    public func ownershipPending(_ binding: NotebookBinding) async throws -> Bool {
        try await stage(binding) { db in try db.core.inReadTransaction {
            try db.lingroveNotebookWindowStore.checkBindingInTransaction(binding.engineBinding)
            return try LingroveNotebookAccountStore(core: db.core).hasPendingProposal(workspaceID: binding.workspace)
        } }
    }

    public func sequence(_ binding: NotebookBinding) async throws -> VocabularyWireSequence? {
        try await stage(binding) { try $0.confirmedLingroveNotebookShadow(binding: binding.engineBinding)?.sequence }
    }

    public func hasConflict(_ binding: NotebookBinding) async throws -> Bool {
        try await stage(binding) { try LingroveNotebookConflictStore(core: $0.core).load(binding: binding.engineBinding) != nil }
    }

    public func next(_ binding: NotebookBinding, staged: VocabularyWireStagedCapabilities?) async throws -> NotebookPendingUpload? {
        try await stage(binding) { try $0.nextLingroveNotebookUpload(binding: binding.engineBinding,
                                                                   stagedCapability: staged)?.networkPending }
    }

    public func control(_ pending: NotebookPendingUpload, binding: NotebookBinding) async throws -> NotebookUploadControl {
        try await stage(binding) { db in
            let value = try db.lingroveNotebookUploadControl(restore(pending, binding: binding, db: db), binding: binding.engineBinding)
            return .init(cancelRequested: value.cancelRequested, hasSettlement: value.hasSettlement)
        }
    }

    public func existing(_ pending: NotebookPendingUpload, binding: NotebookBinding) async throws -> NotebookPendingUpload {
        try await stage(binding) { try restore(pending, binding: binding, db: $0).networkPending }
    }

    public func record(_ outcome: VocabularyWireGroupOutcome, pending: NotebookPendingUpload, binding: NotebookBinding) async throws {
        try await stage(binding) { db in
            _ = try restore(pending, binding: binding, db: db)
            try db.recordLingroveNotebookOutcome(outcome, bodySHA256: pending.bodySHA256, binding: binding.engineBinding)
        }
    }

    public func record(_ manifest: VocabularyWireConfirmationManifest, pending: NotebookPendingUpload,
                       binding: NotebookBinding) async throws {
        try await stage(binding) { db in
            try db.recordLingroveNotebookConfirmation(manifest, pending: restore(pending, binding: binding, db: db),
                                                      binding: binding.engineBinding)
        }
    }

    public func record(_ page: VocabularyWireConfirmationPage, manifest: VocabularyWireConfirmationManifest,
                       pending: NotebookPendingUpload, binding: NotebookBinding) async throws {
        try await stage(binding) { db in
            try db.recordLingroveNotebookConfirmationPage(page, manifest: manifest,
                pending: restore(pending, binding: binding, db: db), binding: binding.engineBinding)
        }
    }

    public func closeUpload(_ manifest: VocabularyWireStagedManifest, pending: NotebookPendingUpload,
                            binding: NotebookBinding) async throws {
        try await stage(binding) { db in
            try db.recordLingroveNotebookUploadClosure(manifest, pending: restore(pending, binding: binding, db: db),
                                                       binding: binding.engineBinding)
        }
    }

    public func authorize(_ authorization: NotebookRetryAuthorization) async throws {
        try await stage(authorization.binding) { db in
            try LingroveNotebookRetryStore(core: db.core).authorize(authorization.engineAuthorization)
        }
    }

    public func begin(_ manifest: VocabularyWireWindowManifest, binding: NotebookBinding) async throws -> [Int] {
        try await stage(binding) { try $0.beginLingroveNotebookWindow(manifest,
            binding: binding.engineBinding, now: Date()).receivedOrdinals }
    }

    public func receive(_ page: VocabularyWireWindowPage, manifest: VocabularyWireWindowManifest, binding: NotebookBinding) async throws {
        try await stage(binding) { try $0.receiveLingroveNotebookWindowPage(page, binding: binding.engineBinding,
            manifestSHA256: manifest.manifestSHA256, now: Date()) }
    }

    public func discard(_ manifest: VocabularyWireWindowManifest, binding: NotebookBinding) async throws {
        try await stage(binding) {
            try $0.discardLingroveNotebookWindow(binding: binding.engineBinding, windowID: manifest.windowID)
        }
    }

    public func windowReferences(_ manifest: VocabularyWireWindowManifest, images: [String: Data],
                                 binding: NotebookBinding) async throws -> [VocabularyImageReference] {
        try await stage(binding) { db in
            let verified = try db.completeLingroveNotebookWindow(binding: binding.engineBinding,
                windowID: manifest.windowID, manifestSHA256: manifest.manifestSHA256, now: Date())
            return try db.prepareLingroveNotebookApply(verified, binding: binding.engineBinding,
                images: images, now: Date()).imageReferences
        }
    }

    public func apply(_ manifest: VocabularyWireWindowManifest, binding: NotebookBinding, images: [String: Data]) async throws {
        try await stage(binding) { db in
            let verified = try db.completeLingroveNotebookWindow(binding: binding.engineBinding,
                windowID: manifest.windowID, manifestSHA256: manifest.manifestSHA256, now: Date())
            let plan = try db.prepareLingroveNotebookApply(verified, binding: binding.engineBinding, images: images, now: Date())
            _ = try db.commitLingroveNotebookApply(plan, now: Date())
        }
    }

    public func revision(_ binding: NotebookBinding) async throws -> Int64 {
        try await stage(binding) { db in try db.core.inReadTransaction {
            try db.lingroveNotebookWindowStore.checkBindingInTransaction(binding.engineBinding)
            return try LingroveNotebookReviewSyncStore(core: db.core).cursor(binding.workspace)
        } }
    }

    public func request(_ binding: NotebookBinding) async throws -> NotebookReviewRequest {
        try await stage(binding) { db in
            let value = try LingroveNotebookReviewSyncStore(core: db.core).request(binding.engineBinding)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try .init(body: encoder.encode(value), afterSequence: value.afterSequence,
                hasWork: !value.enrollments.isEmpty || !value.links.isEmpty || !value.operations.isEmpty
                    || !value.undos.isEmpty || !value.confirmations.isEmpty || !value.historyAdoptions.isEmpty)
        }
    }

    public func apply(_ response: Data, request: NotebookReviewRequest, binding: NotebookBinding) async throws -> Bool {
        guard response.count <= 8 * 1024 * 1024 else { throw NotebookNetworkError.replyTooLarge }
        return try await stage(binding) { db in
            let decoder = JSONDecoder()
            let sent = try decoder.decode(LingroveNotebookReviewRequest.self, from: request.body)
            guard sent.afterSequence == request.afterSequence else { throw NotebookNetworkError.invalidReply }
            let reply = try decoder.decode(LingroveNotebookReviewResponse.self, from: response)
            try LingroveNotebookReviewSyncStore(core: db.core).apply(reply, request: sent, binding: binding.engineBinding)
            return reply.hasMore
        }
    }

    /// The original connection is checked again after background completion. A committed write
    /// whose callback was cancelled remains recoverable through the same durable frozen intent.
    func stage<T: Sendable>(_ binding: NotebookBinding,
                            _ work: @escaping @Sendable (LingroveNotebookEngine) throws -> T) async throws -> T {
        try validate(binding)
        do {
            let result = try await NotebookEngineStage.perform(databaseURL: databaseURL, mediaURL: mediaURL, work: work)
            try validate(binding)
            return result
        } catch { throw networkStorageFailure(error) }
    }
}

/// Only explicit paths and immutable results cross to the concurrent executor. Each invocation
/// owns its connection; a non-Sendable engine or native handle never crosses an actor boundary.
nonisolated enum NotebookEngineStage {
    @concurrent static func perform<T: Sendable>(
        databaseURL: URL, mediaURL: URL,
        work: @escaping @Sendable (LingroveNotebookEngine) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let db = try LingroveNotebookEngine(databaseURL: databaseURL, mediaDirectoryURL: mediaURL)
        do {
            let value = try work(db)
            try db.close()
            return value
        } catch {
            let original = error
            try db.close()
            throw original
        }
    }
}

/// Restores the private journal coverage from SQLite, never from a network projection. Matching
/// frozen bytes prevent a later or forged projection from acknowledging unsent local operations.
private nonisolated func restore(_ pending: NotebookPendingUpload, binding: NotebookBinding,
                                 db: LingroveNotebookEngine) throws -> LingroveNotebookPendingUpload {
    let stored = try db.lingroveNotebookUploadStore.existing(binding: binding.engineBinding, frozenSHA256: pending.frozenSHA256)
    guard stored.body == pending.body else { throw NotebookStorageError.corruptBatch }
    return stored
}
