import Foundation
import LingroveNotebook
import LingroveNotebookSync

/// A run owns this coordinator on the same MainActor as the corpus runner.
/// Network/PNG/SQLite work yields immutable values. The runner's binding check
/// fences every suspension; per-job revisions separately fence user Cancel.
@MainActor
struct NotebookMediaCoordinator {
    let storage: any NotebookMediaStorage
    let transport: NotebookMediaTransport
    let transfers: NotebookMediaTransfers
    let validate: (NotebookBinding) throws -> Void

    func upload(_ pending: NotebookPendingUpload, account: NotebookAccount, binding: NotebookBinding) async throws {
        guard !pending.cancelRequested, pending.outcome == nil, pending.stagedClosure == nil else { return }
        let target = try VocabularyWireProjectionCodec.materializeComplete(pending.batch.targetEntities, notebookID: binding.scope.notebookID).document
        let references = VocabularyDocumentValidation.imageReferences(target)
        guard !references.isEmpty else { return }
        try check(binding)
        let jobs = try await storage.enqueue(references, direction: .upload,
            consumer: "upload:" + pending.batch.request.groupID.uuidString, binding: binding)
        try check(binding)
        // Existing ready mappings need no byte transfer. Negotiate only actual upload work;
        // otherwise a transient media probe could block an unrelated corpus-only edit.
        let work = jobs.filter { $0.state != .ready || $0.remoteAssetID == nil }
        guard !work.isEmpty else { return }
        try await transport.capabilities(account, binding: binding)
        try check(binding)
        for queued in work {
            let job = try await storage.claim(queued, binding: binding, recheckReady: false)
            try await transfer(job, binding: binding) {
                try check(binding)
                let bytes = try await storage.owned(job.reference, binding: binding)
                try await check(job, binding: binding)
                var descriptor = try await transport.metadata(job.reference, action: "prepare", account: account, binding: binding)
                try await check(job, binding: binding)
                if descriptor.state != "ready" {
                    descriptor = try await transport.upload(bytes, reference: job.reference, account: account, binding: binding)
                    try await check(job, binding: binding)
                }
                guard descriptor.state == "ready" else { throw NotebookMediaError.incomplete(.missing) }
                try await storage.complete(job, assetID: descriptor.mediaAssetId, received: nil, binding: binding)
                try check(binding)
            }
        }
    }

    func download(_ references: [VocabularyImageReference], consumer: String, supplied: [String: Data],
                  account: NotebookAccount, binding: NotebookBinding) async throws {
        guard !references.isEmpty else { return }
        try check(binding)
        let jobs = try await storage.enqueue(references, direction: .download, consumer: consumer, binding: binding)
        try check(binding)
        var negotiated = false
        for queued in jobs {
            if (try? await storage.owned(queued.reference, binding: binding)) != nil {
                try check(binding)
                // No transfer is needed for already validated owned bytes.
                // Leave a cancelled job cancelled; local availability is not a
                // user's permission to resume a cancelled network operation.
                try await storage.available(queued, binding: binding)
                try check(binding)
                continue
            }
            let job = try await storage.claim(queued, binding: binding, recheckReady: true)
            try await transfer(job, binding: binding) {
                try check(binding)
                let bytes: Data
                let assetID: UUID?
                if let original = supplied[job.reference.filename] {
                    bytes = original; assetID = nil
                } else {
                    if !negotiated {
                        try await transport.capabilities(account, binding: binding); try await check(job, binding: binding)
                        negotiated = true
                    }
                    let descriptor = try await transport.metadata(job.reference, action: "resolve", account: account, binding: binding)
                    try await check(job, binding: binding)
                    guard descriptor.state == "ready" else { throw NotebookMediaError.incomplete(.missing) }
                    bytes = try await transport.download(job.reference, account: account, binding: binding)
                    try await check(job, binding: binding)
                    assetID = descriptor.mediaAssetId
                }
                try await storage.complete(job, assetID: assetID, received: bytes, binding: binding)
                try check(binding)
            }
        }
    }
    func finish(consumer: String, account: NotebookAccount, binding: NotebookBinding) async throws {
        try check(binding)
        try await storage.release(consumer: consumer, binding: binding)
        try check(binding)
        let unused = try await storage.prune(binding: binding)
        for reference in unused {
            try check(binding)
            try await transport.release(reference, account: account, binding: binding)
            try check(binding)
            try await storage.acknowledgeRelease(reference, binding: binding)
            try check(binding)
        }
    }
    /// Admission can fail after SQLite claimed the attempt (for example while
    /// a cancelled prior task unwinds). The same revision-CAS failure path must
    /// clear that lease too; otherwise an immediate Retry would wait a minute.
    private func transfer(_ job: NotebookMediaJob, binding: NotebookBinding,
                          operation: @escaping @MainActor () async throws -> Void) async throws {
        do { try await transfers.perform(job, operation: operation) }
        catch {
            try await failed(job, error: error, binding: binding)
            throw error
        }
    }
    private func failed(_ job: NotebookMediaJob, error: Error, binding: NotebookBinding) async throws {
        try check(binding)
        let state: NotebookMediaState
        if case NotebookNetworkError.http(404, _) = error { state = .missing }
        else if error as? NotebookMediaError == .incomplete(.missing) { state = .missing }
        else if isCloudCancellation(error) || error as? NotebookMediaError == .busy { state = .queued }
        else { state = .failed }
        // A user's newer cancellation/retry wins over an older HTTP failure.
        do { try await storage.fail(job, state: state, binding: binding) }
        catch NotebookMediaError.staleAttempt { }
        catch NotebookMediaError.incomplete(.cancelled) { }
        try check(binding)
    }
    private func check(_ job: NotebookMediaJob, binding: NotebookBinding) async throws {
        try check(binding)
        try await storage.check(job, binding: binding)
        try check(binding)
    }
    private func check(_ binding: NotebookBinding) throws { try Task.checkCancellation(); try validate(binding) }
}
