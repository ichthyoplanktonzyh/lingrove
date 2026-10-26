import Foundation
import CoreGraphics

/// One app-owned module serializes every context/reading OCR operation. Its dedicated native
/// thread owns helper startup, image preparation, IPC and teardown; no synchronous work occupies
/// MainActor or the cooperative/global Dispatch pools. The condition protects only admission and
/// shutdown. It is never held across image work, I/O, callbacks or continuation resumption.
nonisolated final class OCRRuntime: @unchecked Sendable {
    /// These are internal resource limits, not preferences. Tests use short deadlines with a
    /// disposable helper; production gives explicit region reading more time than background OCR.
    nonisolated struct Configuration: Sendable {
        var contextTimeout: TimeInterval = 4
        var readingTimeout: TimeInterval = 12
        var retryDelay: TimeInterval = 1
        var cooldown: TimeInterval = 30
        var idleTimeout: TimeInterval = 60
    }

    private let condition = NSCondition()
    private let helperURL: URL
    private let configuration: Configuration
    private let events: @Sendable (String, [String: String]) -> Void
    private var pending: [OCRRequestPurpose: OCRWork] = [:]
    private var active: OCRWork?
    private var startedThread = false
    private var closed = false
    private var failures = 0
    private var retryAfter = 0.0
    private var helperProcessID: Int32?

    /// A lock-protected identity snapshot for the existing visible-pane resource sampler.
    /// Only the native transport thread reads Process itself; observing this never starts OCR.
    var processID: Int32? { condition.withLock { helperProcessID } }

    init(helperURL: URL? = nil, configuration: Configuration = .init(),
         events: @escaping @Sendable (String, [String: String]) -> Void = { _, _ in }) {
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lingrove-ocr-helper")
        self.configuration = configuration
        self.events = events
    }

    func recognize(_ image: CGImage, options: OCRRequestOptions) async throws -> OCRWorkerResponse {
        let work = OCRWork(image: image, options: options)
        let expiry = options.deadline.map { deadline in
            Task { [self, work] in
                do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) } catch { return }
                work.finish(.failure(OCRRuntimeFailure.timedOut))
                discardPending(work)
            }
        }
        defer { expiry?.cancel() }
        let result: OCRWorkerResponse = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if work.install(continuation) { enqueue(work) }
            }
        } onCancel: {
            work.cancel()
            self.discardPending(work)
        }
        try Task.checkCancellation()
        return result
    }

    /// Fast and synchronous for AppDelegate's exit path. Native I/O checks this flag every poll;
    /// the helper also watches parent death, so even an immediate app exit cannot orphan Vision.
    func shutdown() {
        condition.lock()
        closed = true
        let retiring = Array(pending.values) + (active.map { [$0] } ?? [])
        pending.removeAll()
        condition.broadcast()
        condition.unlock()
        retiring.forEach { $0.cancel() }
    }

    private var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    private func enqueue(_ work: OCRWork) {
        condition.lock()
        let failure: OCRRuntimeFailure? = closed ? .shuttingDown :
            (ProcessInfo.processInfo.systemUptime < retryAfter ? .unavailable : nil)
        let replaced: OCRWork?
        let shouldStart: Bool
        let didEnqueue: Bool
        if failure == nil && !work.isCancelled {
            replaced = pending.updateValue(work, forKey: work.options.purpose)
            shouldStart = !startedThread
            didEnqueue = true
            startedThread = true
            condition.signal()
        } else { replaced = nil; shouldStart = false; didEnqueue = false }
        let queuedCount = pending.count
        condition.unlock()
        replaced?.cancel()
        if let failure { work.finish(.failure(failure)) }
        if didEnqueue {
            events("OCR request queued", ["request_id": work.id, "phase": "queued", "pending_count": String(queuedCount)])
        }
        if shouldStart {
            // This is intentionally an OS thread, not Task.detached or a serial Dispatch queue:
            // blocking native/pipe work must not consume the app's shared executor capacity.
            let thread = Thread { self.runLoop() }
            thread.name = "Lingrove OCR transport"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private func discardPending(_ work: OCRWork) {
        condition.lock()
        if pending[work.options.purpose] === work { pending.removeValue(forKey: work.options.purpose) }
        condition.unlock()
    }

    private func takeNext() -> OCRWork? {
        condition.lock()
        defer { condition.unlock() }
        if pending.isEmpty && !closed {
            _ = condition.wait(until: Date(timeIntervalSinceNow: max(0.05, configuration.idleTimeout)))
        }
        guard !closed else { return nil }
        // Explicit reading wins over background context that has not started. At most one
        // image for each purpose remains queued; superseded callers already received cancellation.
        let purpose: OCRRequestPurpose = pending[.reading] != nil ? .reading : .visualContext
        let work = pending.removeValue(forKey: purpose)
        active = work
        return work
    }

    private func runLoop() {
        let worker = OCRWorkerProcess(executable: helperURL) { pid in
            self.condition.withLock { self.helperProcessID = pid }
        }
        var mustRetire = false
        var lastUsed = ProcessInfo.processInfo.systemUptime
        while !isClosed {
            guard let work = takeNext() else {
                if ProcessInfo.processInfo.systemUptime - lastUsed >= configuration.idleTimeout { mustRetire = !worker.stop() }
                continue
            }
            if work.isCancelled { clearActive(work); continue }
            if mustRetire { mustRetire = !worker.stop() }
            if mustRetire {
                work.finish(.failure(OCRRuntimeFailure.unavailable))
                recordFailure(.unavailable, work: work)
            } else {
                let failure: OCRRuntimeFailure? = autoreleasepool { execute(work, worker: worker) }
                if let failure {
                    // Retain the only child until exit is confirmed. A slow reap can reduce OCR
                    // availability, but cannot admit a second worker alongside a stuck first one.
                    mustRetire = !worker.stop()
                    recordFailure(failure, work: work)
                }
            }
            lastUsed = ProcessInfo.processInfo.systemUptime
            clearActive(work)
        }
        _ = worker.stop()
    }

    private func execute(_ work: OCRWork, worker: OCRWorkerProcess) -> OCRRuntimeFailure? {
        let started = ProcessInfo.processInfo.systemUptime
        let timeout = work.options.purpose == .reading ? configuration.readingTimeout : configuration.contextTimeout
        let deadline = min(started + timeout, work.options.deadline ?? .infinity)
        guard deadline > started else {
            // An expired queued crop never touched the child or its pipe. Keep the healthy
            // worker available instead of treating this caller's budget as a native failure.
            work.finish(.failure(OCRRuntimeFailure.timedOut))
            return nil
        }
        events("OCR request started", ["request_id": work.id, "origin": String(describing: work.options.purpose), "phase": "started"])
        do {
            let result = try worker.recognize(image: work.image, options: work.options, id: work.id,
                deadline: deadline, isShuttingDown: { self.isClosed }, isCancelled: { work.isCancelled })
            condition.lock(); failures = 0; condition.unlock()
            // A logical cancel releases the caller immediately, but this work retains the native
            // execution slot until its response arrives or its helper has been retired.
            work.finish(.success(result))
            events("OCR request finished", ["request_id": work.id, "phase": "finished",
                "helper_pid": String(worker.identifier ?? 0), "cancelled": String(work.isCancelled),
                "preparation_ms": String(worker.preparationMilliseconds),
                "latency_ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1_000))])
            return nil
        } catch is CancellationError {
            work.finish(.failure(CancellationError()))
            events("OCR request skipped before sending", ["request_id": work.id, "phase": "skipped"])
            return nil
        } catch let failure as OCRRuntimeFailure {
            work.finish(.failure(failure))
            switch failure {
            case .invalidImage, .noRecognizedText: return nil
            default: return failure
            }
        } catch {
            work.finish(.failure(OCRRuntimeFailure.invalidResponse))
            return .invalidResponse
        }
    }

    private func clearActive(_ work: OCRWork) {
        condition.lock()
        if active === work { active = nil }
        condition.unlock()
    }

    private func recordFailure(_ failure: OCRRuntimeFailure, work: OCRWork) {
        condition.lock()
        failures += 1
        let delay = failures >= 3 ? configuration.cooldown : configuration.retryDelay
        retryAfter = ProcessInfo.processInfo.systemUptime + delay
        let rejected = Array(pending.values)
        pending.removeAll()
        condition.unlock()
        rejected.forEach { $0.finish(.failure(OCRRuntimeFailure.unavailable)) }
        events("OCR worker retired", ["request_id": work.id, "phase": "retired",
                                      "failure": failure.rawValue, "backoff_seconds": String(delay)])
    }
}

/// One admitted/queued request owns its immutable image and a single-resumption continuation.
/// Swift cancellation can race installation, completion, and queue replacement; the lock picks
/// one terminal outcome. Continuations always resume outside it, allowing caller reentrancy.
private nonisolated final class OCRWork: @unchecked Sendable {
    let id = UUID().uuidString
    let image: CGImage
    let options: OCRRequestOptions
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OCRWorkerResponse, Error>?
    private var result: Result<OCRWorkerResponse, Error>?
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }

    init(image: CGImage, options: OCRRequestOptions) { self.image = image; self.options = options }

    func install(_ continuation: CheckedContinuation<OCRWorkerResponse, Error>) -> Bool {
        lock.lock()
        let completed = result
        if completed == nil { self.continuation = continuation }
        lock.unlock()
        if let completed { continuation.resume(with: completed) }
        return completed == nil
    }

    func cancel() {
        lock.withLock { cancelled = true }
        finish(.failure(CancellationError()))
    }

    func finish(_ result: Result<OCRWorkerResponse, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        let resolved: Result<OCRWorkerResponse, Error> = cancelled ? .failure(CancellationError()) : result
        self.result = resolved
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: resolved)
    }
}
