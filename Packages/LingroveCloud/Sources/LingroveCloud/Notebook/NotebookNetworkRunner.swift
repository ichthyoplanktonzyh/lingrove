import Foundation
import LingroveNotebookSync

/// The application owns the runner together with its existing LocalDatabase.
/// One run resolves at most one frozen group and applies a verified window.
/// Networking suspends outside SQLite transactions; every response is fenced
/// by the account generation captured before capability/connection requests.
@MainActor
public struct NotebookNetworkRunner {
    private let storage: any NotebookStorage
    private let mediaStorage: any NotebookMediaStorage
    private let transport: NotebookHTTPTransport
    private let mediaTransport: NotebookMediaTransport
    private let transfers: NotebookMediaTransfers
    public init(storage: any NotebookStorage, mediaStorage: any NotebookMediaStorage,
                transport: NotebookHTTPTransport = .init(), mediaTransport: NotebookMediaTransport = .init(),
                transfers: NotebookMediaTransfers = .init()) {
        self.storage = storage; self.mediaStorage = mediaStorage; self.transport = transport
        self.mediaTransport = mediaTransport; self.transfers = transfers
    }
    private var media: NotebookMediaCoordinator {
        .init(storage: mediaStorage, transport: mediaTransport, transfers: transfers, validate: { try check($0) })
    }

    public func synchronize(_ account: NotebookAccount, images: [String: Data] = [:], retryAuthorization: NotebookRetryAuthorization? = nil) async throws -> NotebookNetworkResult {
        // Resolve the trusted owner before restoring a per-workspace replica.
        // A reconnect reuses the original installation and exact frozen body.
        let installation = try storage.installation(for: account)
        guard let workspace = UUID(uuidString: account.workspaceId) else {
            throw NotebookNetworkError.identityMismatch
        }
        // Unknown remote book/replica IDs are placeholders only for capturing
        // the pre-request account generation. They are never persisted/adopted.
        let ticket = try storage.capture(scope: .init(ownerUserID: account.userId,
            workspaceID: workspace, notebookID: UUID(), replicaID: installation))
        if let retryAuthorization {
            try check(retryAuthorization.binding)
            try await storage.authorize(retryAuthorization)
            try check(ticket)
        }
        let capabilities = try await transport.capabilities(account)
        try check(ticket)
        let connection = try await transport.connect(account, installationID: installation)
        let scope = VocabularyWireWindowScope(ownerUserID: account.userId, workspaceID: workspace,
            notebookID: connection.notebookID, replicaID: connection.replicaID)
        let binding = NotebookBinding(scope: scope, generation: ticket.generation)
        try check(binding)
        // Background synchronization can reach a newly linked workspace before
        // its notebook screen has ever opened. Create only its revision-zero
        // local header; existing books/documents are never replaced here.
        _ = try await storage.initial(binding)
        try check(binding)
        if try await storage.ownershipPending(binding) {
            throw NotebookStorageError.ownershipRequired
        }
        // A previously confirmed different book/replica fails here. Reopening
        // metadata must never silently rebind an existing notebook or batch.
        let sequence = try await storage.sequence(binding)
        try check(binding)
        let first: NotebookNetworkResult?
        if sequence != nil, try await storage.hasConflict(binding) {
            // Resume choices against a fresh canonical window before creating
            // another upload identity. Unresolved conflicts retain all intent.
            return try await pull(account, binding: binding, outcome: nil, images: images, freshAfterSettlement: true)
        }
        if sequence == nil { first = try await pull(account, binding: binding, outcome: nil, images: images) }
        else { first = nil }
        let pending: NotebookPendingUpload?
        do {
            try check(binding)
            pending = try await storage.next(binding, staged: capabilities.stagedUploads)
            try check(binding)
        } catch NotebookStorageError.cancelledUpload {
            // Upload cancellation does not disable receiving remote corpus
            // changes. A pull adds no public-edit journal and keeps the gate.
            return try await pull(account, binding: binding, outcome: nil, images: images)
        } catch NotebookStorageError.rejectedIntent {
            return try await pull(account, binding: binding, outcome: nil, images: images)
        }
        if let pending {
            return try await settle(pending, account: account, binding: binding, images: images, capability: capabilities.stagedUploads,
                priorCleanup: first?.cleanupPending ?? false)
        }
        if let first { return first }
        return try await pull(account, binding: binding, outcome: nil, images: images)
    }

    private func settle(_ pending: NotebookPendingUpload, account: NotebookAccount, binding: NotebookBinding,
                        images: [String: Data], capability: VocabularyWireStagedCapabilities?,
                        priorCleanup: Bool = false) async throws -> NotebookNetworkResult {
        try check(binding)
        try await media.upload(pending, account: account, binding: binding)
        try check(binding)
        // Media can suspend for seconds. Re-read the durable cancellation bit
        // before deciding whether the frozen corpus request is apply or cancel.
        let pending = try await storage.existing(pending, binding: binding)
        try check(binding)
        let outcome: VocabularyWireGroupOutcome?
        let transferCleanup: Bool
        if pending.batch.transport == .staged {
            let transfer = NotebookStagedTransfer(transport: transport, storage: storage, validate: { try check(binding) })
            let resolved = try await transfer.settle(pending, account: account, binding: binding, capability: capability)
            outcome = resolved.pending.outcome; transferCleanup = resolved.cleanupPending
        } else {
            let direct = try await transport.settle(pending, account: account)
            outcome = direct
            try check(binding)
            try await storage.record(direct, pending: pending, binding: binding)
            transferCleanup = false
        }
        try check(binding)
        let applied = try await pull(account, binding: binding, outcome: outcome, images: images, freshAfterSettlement: true)
        var mediaCleanup = false
        do { try await media.finish(consumer: "upload:" + pending.batch.request.groupID.uuidString, account: account, binding: binding) }
        catch {
            if isCloudCancellation(error) { throw error }
            mediaCleanup = true
        }
        let state = try await storage.state(binding)
        try check(binding)
        return .init(binding: binding, state: state, outcome: outcome, cleanupPending: priorCleanup || applied.cleanupPending || transferCleanup || mediaCleanup, uploadCancelled: state.uploadCancelled)
    }

    private func pull(_ account: NotebookAccount, binding: NotebookBinding, outcome: VocabularyWireGroupOutcome?,
                      images: [String: Data], freshAfterSettlement: Bool = false) async throws -> NotebookNetworkResult {
        try check(binding)
        let sequence = try await storage.sequence(binding)
        try check(binding)
        var manifest = try await transport.openWindow(account, scope: binding.scope, after: sequence)
        try check(binding)
        if freshAfterSettlement || outcome != nil {
            // Open can replay a lease created before this group settled. Release
            // that one identity before opening a fresh canonical snapshot; an
            // uncertain release leaves the frozen outcome intact for retry.
            try await transport.release(manifest, account: account)
            try check(binding)
            try await storage.discard(manifest, binding: binding)
            try check(binding)
            manifest = try await transport.openWindow(account, scope: binding.scope, after: sequence)
            try check(binding)
        }
        if case let .committed(receipt)? = outcome {
            guard manifest.highWaterSequence >= receipt.committedSequence else { throw VocabularyWireUploadError.incompleteReceiptCoverage }
        }
        let stage = try await storage.begin(manifest, binding: binding)
        try check(binding)
        let received = Set(stage)
        for ordinal in 0..<manifest.pageCount where !received.contains(ordinal) {
            try check(binding)
            let page = try await transport.page(ordinal, manifest: manifest, account: account)
            try check(binding)
            try await storage.receive(page, manifest: manifest, binding: binding)
            try check(binding)
        }
        let references = try await storage.windowReferences(manifest, images: images, binding: binding)
        try check(binding)
        let consumer = "window:" + manifest.windowID.uuidString.lowercased()
        try await media.download(references, consumer: consumer, supplied: images, account: account, binding: binding)
        try check(binding)
        _ = try await storage.apply(manifest, binding: binding, images: images)
        try check(binding)
        var cleanupPending = false
        do { try await storage.discard(manifest, binding: binding) }
        catch { cleanupPending = true }
        try check(binding)
        do { try await media.finish(consumer: consumer, account: account, binding: binding) }
        catch {
            if isCloudCancellation(error) { throw error }
            cleanupPending = true
        }
        try check(binding)
        do { try await transport.release(manifest, account: account) }
        catch {
            if isCloudCancellation(error) { throw error }
            cleanupPending = true
        }
        try check(binding)
        let state = try await storage.state(binding)
        try check(binding)
        return .init(binding: binding, state: state, outcome: outcome, cleanupPending: cleanupPending, uploadCancelled: state.uploadCancelled)
    }

    private func check(_ binding: NotebookBinding) throws {
        try Task.checkCancellation()
        try storage.validate(binding)
    }
}
