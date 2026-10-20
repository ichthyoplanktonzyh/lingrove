import Foundation
import Darwin

/// The router asks this service for optional rich content. A helper crash, timeout or missing
/// private symbol is a normal absence. The helper can use public text from the same language-
/// matched book; if metadata selection itself is unavailable the router tries another provider.
nonisolated struct SystemDictionaryArticleService: Sendable {
    var executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lingrove-dictionary-helper")

    func lookup(_ query: String, language: LearningLanguage? = nil,
                definitionLanguage: LearningLanguage? = nil) async throws -> LearningDictionaryArticle? {
        let operation = DictionaryHelperOperation()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try operation.run(executable: executable, query: query,
                            language: language, definitionLanguage: definitionLanguage))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { operation.cancel() }
        // Killing the helper may close stdout before its reader observes the cancel flag.
        // Recheck the Swift task so that EOF from cancellation cannot become a normal miss.
        try Task.checkCancellation()
        return result
    }
}

/// Only this lock-protected bridge shares Process across a cancellation callback and a blocking
/// pipe reader. Heavy native calls and pipe waits never run on MainActor or an actor executor.
private nonisolated final class DictionaryHelperOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var didStart = false
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        if didStart, let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        lock.unlock()
    }

    func run(executable: URL, query: String, language: LearningLanguage?,
             definitionLanguage: LearningLanguage?) throws -> LearningDictionaryArticle? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let child = Process(), pipe = Pipe(), exited = DispatchSemaphore(value: 0)
        child.executableURL = executable
        child.arguments = [query]
        if let language { child.arguments = [query, language.rawValue, definitionLanguage?.rawValue ?? "en"] }
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { _ in exited.signal() }
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        process = child
        lock.unlock()
        // Process startup must not hold the cancellation lock: cancelling from MainActor must
        // stay immediate even while the OS is starting a cold helper executable.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        do { try child.run() } catch {
            lock.lock(); process = nil; lock.unlock()
            return nil
        }
        lock.lock()
        didStart = true
        if cancelled, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        lock.unlock()
        // This bundled helper never forks. Nonblocking reads bound stdout waits independently
        // of its native dictionary calls; readToEnd and waitUntilExit have no such bound.
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        defer {
            lock.lock()
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            process = nil
            didStart = false
            lock.unlock()
            pipe.fileHandleForReading.closeFile()
            // Foundation reaps Process asynchronously; allow its termination callback to finish
            // without turning a timeout or cancellation into another unbounded wait.
            _ = exited.wait(timeout: .now() + 0.5)
        }
        guard let output = try readOutput(descriptor: descriptor, deadline: deadline),
              exited.wait(timeout: .now() + 0.2) == .success,
              child.terminationStatus == 0, !output.isEmpty else { return nil }
        // A consumed semaphore should not make defer wait another half second on success.
        exited.signal()
        struct Payload: Decodable {
            let html: String; let text: String; let sourceName: String
            var entryLanguage: String?; var definitionLanguage: String?
        }
        guard let result = try? JSONDecoder().decode(Payload.self, from: output) else { return nil }
        return .init(html: result.html, text: result.text, sourceName: result.sourceName,
            languages: .init(entry: result.entryLanguage.flatMap(LearningLanguage.init(rawValue:)),
                             definition: result.definitionLanguage.flatMap(LearningLanguage.init(rawValue:))))
    }

    private func readOutput(descriptor: Int32, deadline: ContinuousClock.Instant) throws -> Data? {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { throw CancellationError() }
            guard ContinuousClock.now < deadline else { return nil }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&event, 1, 100)
            if ready < 0 { return nil }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 { return nil }
            guard output.count + count <= 2_000_000 else { return nil }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }
}
