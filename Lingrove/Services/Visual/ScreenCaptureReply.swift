import Foundation

/// One ScreenCaptureKit callback owns one reply. The lock arbitrates callback, timeout and task
/// cancellation; late callbacks release their SDK value without resuming a retired continuation.
/// The SDK operation itself is not cancelled. This object owns no pixels after delivery.
nonisolated final class ScreenCaptureReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func wait(deadline: TimeInterval, isolation: isolated (any Actor)? = #isolation,
              start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        guard deadline > ProcessInfo.processInfo.systemUptime else { throw OCRRuntimeFailure.timedOut }
        let timeout = Task { [self] in
            let seconds = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            finish(.failure(OCRRuntimeFailure.timedOut))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiting in
                lock.lock()
                let completed = result
                if completed == nil { continuation = waiting }
                lock.unlock()
                if let completed { waiting.resume(with: completed) } else { start { self.finish($0) } }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ value: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        // Retain only a terminal failure when no waiter has installed yet. A successful SDK
        // callback is started after installation and must not keep its potentially large image.
        let waiting = continuation
        continuation = nil
        result = .failure(CancellationError())
        if waiting == nil { result = value }
        lock.unlock()
        waiting?.resume(with: value)
    }
}
