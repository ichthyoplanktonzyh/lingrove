import Foundation
import LingroveNotebookSync

/// One in-flight frozen ticket owns this state machine. The runner supplies
/// its original-Core continuation fence; SyncIO owns temporary SQLite access.
/// A run sends each missing chunk at most once and settles only this identity.
@MainActor
struct NotebookStagedTransfer {
    let transport: NotebookHTTPTransport
    let storage: any NotebookStorage
    let validate: @MainActor () throws -> Void
    struct Settlement {
        let pending: NotebookPendingUpload
        let cleanupPending: Bool
    }

    func settle(_ pending: NotebookPendingUpload, account: NotebookAccount, binding: NotebookBinding,
                capability: VocabularyWireStagedCapabilities?) async throws -> Settlement {
        if pending.outcome != nil || pending.stagedClosure != nil { return .init(pending: pending, cleanupPending: pending.stagedClosure != nil) }
        guard let capability, let upload = pending.stagedUpload else { throw NotebookNetworkError.stagedUnavailable }
        var current = pending
        var cleanupPending = false
        if current.confirmationManifest == nil {
            let result = try await transfer(pending, upload: upload, account: account, binding: binding, capability: capability)
            switch result {
            case let .confirmed(manifest): try await checked { try await storage.record(manifest, pending: pending, binding: binding) }
            case let .closed(manifest):
                // First durably remember the decision, then try bounded cleanup.
                // A failed cleanup must never turn a known closure into an
                // unknown request that might be retransmitted after restart.
                try await checked { try await storage.closeUpload(manifest, pending: pending, binding: binding) }
                cleanupPending = !manifest.payloadRetired
                if cleanupPending {
                    do {
                        let cleaned = try await checked { try await transport.stagedStatus(upload, account: account) }
                        guard cleaned.state == manifest.state else { throw NotebookNetworkError.invalidReply }
                        cleanupPending = !cleaned.payloadRetired
                    } catch {
                        try validate()
                        if isCloudCancellation(error) { throw error }
                        if case let NotebookNetworkError.http(status, _) = error, status == 401 || status == 410 { throw error }
                        cleanupPending = true
                    }
                }
            case .stored: break
            }
            current = try await checked { try await storage.existing(pending, binding: binding) }
        }
        if current.outcome != nil || current.stagedClosure != nil { return .init(pending: current, cleanupPending: cleanupPending) }
        guard let manifest = current.confirmationManifest else { throw NotebookStorageError.awaitingReceipt }
        let received = Set(current.receivedConfirmationOrdinals)
        for ordinal in 0..<manifest.pageCount where !received.contains(ordinal) {
            let page = try await checked { try await transport.stagedConfirmationPage(ordinal, manifest: manifest, upload: upload, account: account) }
            try await checked { try await storage.record(page, manifest: manifest, pending: current, binding: binding) }
        }
        let verified = try await checked { try await storage.existing(pending, binding: binding) }
        guard verified.outcome != nil else { throw VocabularyWireStagedError.incompleteConfirmation }
        return .init(pending: verified, cleanupPending: cleanupPending)
    }

    private enum Result { case confirmed(VocabularyWireConfirmationManifest), closed(VocabularyWireStagedManifest), stored }
    private func transfer(_ pending: NotebookPendingUpload, upload: VocabularyWireStagedUpload,
                          account: NotebookAccount, binding: NotebookBinding, capability: VocabularyWireStagedCapabilities) async throws -> Result {
        var progress: VocabularyWireStagedManifest
        do { progress = try await checked { try await transport.stagedStatus(upload, account: account) } }
        catch NotebookNetworkError.http(404, "NOTEBOOK_UPLOAD_NOT_FOUND") {
            try capability.validate(bodyBytes: upload.body.count, members: upload.batch.request.members.count)
            progress = try await checked { try await transport.openStaged(upload, account: account) }
        }
        if progress.state == .open {
            let missing = (0..<upload.chunkCount).filter { !progress.receivedOrdinals.contains($0) }
            for ordinal in missing {
                let control = try await checked { try await storage.control(pending, binding: binding) }
                if control.hasSettlement { return .stored }
                if control.cancelRequested { return try await abort(upload, account: account) }
                try capability.validate(bodyBytes: upload.body.count, members: upload.batch.request.members.count)
                let before = Set(progress.receivedOrdinals)
                do {
                    progress = try await checked { try await transport.sendStagedChunk(ordinal, upload: upload, progress: progress, account: account) }
                } catch {
                    guard needsStatus(error) else { throw error }
                    let status = try await checked { try await transport.stagedStatus(upload, account: account) }
                    if status.state == .open { throw error }
                    return try await terminal(status, upload: upload, account: account)
                }
                if progress.state != .open { return try await terminal(progress, upload: upload, account: account) }
                guard before.isSubset(of: Set(progress.receivedOrdinals)), progress.receivedOrdinals.contains(ordinal) else {
                    throw NotebookNetworkError.invalidReply
                }
            }
            let control = try await checked { try await storage.control(pending, binding: binding) }
            if control.hasSettlement { return .stored }
            if control.cancelRequested { return try await abort(upload, account: account) }
            try capability.validate(bodyBytes: upload.body.count, members: upload.batch.request.members.count)
            do {
                return .confirmed(try await checked { try await transport.finalizeStaged(upload, progress: progress, account: account) })
            } catch {
                guard needsStatus(error) else { throw error }
                let status = try await checked { try await transport.stagedStatus(upload, account: account) }
                if status.state == .open { throw error }
                return try await terminal(status, upload: upload, account: account)
            }
        }
        return try await terminal(progress, upload: upload, account: account)
    }
    private func abort(_ upload: VocabularyWireStagedUpload, account: NotebookAccount) async throws -> Result {
        let progress = try await checked { try await transport.abortStaged(upload, account: account) }
        return try await terminal(progress, upload: upload, account: account)
    }
    private func terminal(_ progress: VocabularyWireStagedManifest, upload: VocabularyWireStagedUpload, account: NotebookAccount) async throws -> Result {
        switch progress.state {
        case .aborted, .expired: return .closed(progress)
        case .finalized: return .confirmed(try await checked { try await transport.stagedConfirmation(upload, account: account) })
        case .open: throw NotebookNetworkError.invalidReply
        }
    }
    private func needsStatus(_ error: any Error) -> Bool {
        if error as? VocabularyWireStagedError == .expiredUpload { return true }
        if case let NotebookNetworkError.http(status, code) = error {
            return ((status == 409 || status == 410) && code == "NOTEBOOK_UPLOAD_CLOSED")
                || (status == 409 && code == "NOTEBOOK_UPLOAD_INCOMPLETE")
        }
        return false
    }
    private func checked<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        try validate(); let value = try await operation(); try validate(); return value
    }
}
