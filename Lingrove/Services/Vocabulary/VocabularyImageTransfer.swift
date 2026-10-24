import Foundation

/// One drag/paste operation owns this callback bridge. Task cancellation must release its
/// continuation even when the other application's provider never replies. The lock protects
/// callback/cancellation races; continuations and Progress are always resumed/cancelled outside
/// it because either action can synchronously call back into the provider.
nonisolated final class VocabularyImageTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var progress: Progress?
    private var finished = false

    @MainActor static func load(_ provider: NSItemProvider, type: String) async throws -> Data {
        let transfer = VocabularyImageTransfer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard transfer.register(continuation) else { continuation.resume(throwing: CancellationError()); return }
                let progress = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    if let data { transfer.resolve(.success(data)) } else {
                        transfer.resolve(.failure(error ?? VocabularyError.invalidContent))
                    }
                }
                transfer.setProgress(progress)
            }
        } onCancel: { transfer.resolve(.failure(CancellationError()), cancelling: true) }
    }

    private func register(_ continuation: CheckedContinuation<Data, any Error>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        self.continuation = continuation
        return true
    }

    private func setProgress(_ progress: Progress) {
        lock.lock()
        let cancel = finished
        if !finished { self.progress = progress }
        lock.unlock()
        if cancel { progress.cancel() }
    }

    private func resolve(_ result: Result<Data, any Error>, cancelling: Bool = false) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation, progress = progress
        self.continuation = nil; self.progress = nil
        lock.unlock()
        if cancelling { progress?.cancel() }
        continuation?.resume(with: result)
    }
}
