import Darwin
import Foundation
import Logging

/// An app-owned actor consumes the private filesystem mailbox. A passive directory event source
/// wakes it only when a request is published; normal typing creates no polling or disk activity.
/// One lifetime flock owns consumption, while the archive owns content transactions and replay.
actor CLIMailboxServer {
    let root: URL
    private let handle: @Sendable (CLIRequest) async -> CLIReply
    private var monitor: CLIDirectoryMonitor?
    private var work: Task<Void, Never>?
    private var stopWork: Task<Void, Never>?
    private var stopping = false

    init(root: URL, handle: @escaping @Sendable (CLIRequest) async -> CLIReply) { self.root = root; self.handle = handle }

    func start() async throws {
        if let stopWork { await stopWork.value }
        guard monitor == nil else { return }
        try CLIFileIO.ensureDirectory(root)
        for name in ["requests", "working", "replies"] { try CLIFileIO.ensureDirectory(root.appendingPathComponent(name)) }
        let lease = Darwin.open(root.appendingPathComponent("server.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard lease >= 0 else { throw CLIError(code: .io, message: "Cannot open CLI server lease.") }
        var info = stat()
        guard fstat(lease, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            Darwin.close(lease); throw CLIError(code: .io, message: "Invalid CLI server lease file.")
        }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lease); throw CLIError(code: .busy, message: "Another instance owns the CLI mailbox.") }
        do {
            // A prior crash may have committed before acknowledging. Requeue its claimed files;
            // the durable receipt resolves each write before any candidate can be committed twice.
            for url in files("working") {
                let destination = root.appendingPathComponent("requests").appendingPathComponent(url.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: url, to: destination) }
                else { try FileManager.default.removeItem(at: url) }
            }
            monitor = try CLIDirectoryMonitor(directory: root.appendingPathComponent("requests"), lease: lease) { [weak self] in
                Task { await self?.schedule() }
            }
        } catch { Darwin.close(lease); throw error }
        stopping = false; schedule()
        CotabbyLogger.learning.info("Vocabulary CLI server started")
    }

    func stop() async {
        if let stopWork { await stopWork.value; return }
        stopping = true
        let task = Task { await finishStop() }; stopWork = task
        await task.value
    }

    private func finishStop() async {
        await work?.value
        await monitor?.cancelAndWait()
        monitor = nil; stopWork = nil
    }

    private func schedule() {
        guard !stopping, work == nil else { return }
        work = Task { await drain() }
    }

    private func files(_ name: String) -> [URL] {
        let directory = root.appendingPathComponent(name)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        var result: [URL] = []
        while result.count < 128, let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil { result.append(url) }
        }
        return result
    }

    private func drain() async {
        defer { work = nil }
        while !stopping, let pending = files("requests").first {
            let claimed = root.appendingPathComponent("working").appendingPathComponent(pending.lastPathComponent)
            let replyURL = root.appendingPathComponent("replies").appendingPathComponent(pending.lastPathComponent)
            guard let id = UUID(uuidString: pending.deletingPathExtension().lastPathComponent) else { continue }
            do { try FileManager.default.moveItem(at: pending, to: claimed) } catch { continue }
            let reply: CLIReply
            do {
                let request = try JSONDecoder().decode(CLIRequest.self, from: CLIFileIO.read(claimed))
                guard request.id == id, request.version == 1 else { throw CLIError.invalid("Request identity or protocol version does not match.") }
                reply = await handle(request)
            } catch let error as CLIError { reply = .failure(id, error) }
            catch { reply = .failure(id, .invalid("Invalid CLI request JSON.")) }
            do {
                var bytes = try JSONEncoder().encode(reply)
                if bytes.count > CLIInputPolicy.maximumBytes {
                    bytes = try JSONEncoder().encode(CLIReply.failure(id, .invalid("Response exceeds 32 MiB. Use the app's export for this entry.")))
                }
                if !FileManager.default.fileExists(atPath: replyURL.path) { try CLIFileIO.publish(bytes, to: replyURL) }
                try FileManager.default.removeItem(at: claimed)
                CotabbyLogger.learning.info("Vocabulary CLI request completed", metadata: ["request_id": .string(id.uuidString), "success": .stringConvertible(reply.ok)])
            } catch {
                // Retain the claimed message for recovery on next start. The client can retry
                // immediately with the same key even if writing this acknowledgement failed.
                CotabbyLogger.learning.error("Vocabulary CLI acknowledgement failed", metadata: ["request_id": .string(id.uuidString)])
            }
        }
        // Replies normally disappear when consumed. Retire abandoned responses after a day;
        // idempotency receipts remain in SQLite and are never expired by this file cleanup.
        for url in files("replies") {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < Date().addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: url) }
        }
    }
}

/// Owns the two native descriptors for the actor's monitor lifetime. The cancellation handler
/// closes them after Dispatch stops delivering events; it captures integers, never the actor.
nonisolated private final class CLIDirectoryMonitor {
    private let source: DispatchSourceFileSystemObject
    private let descriptor: Int32
    private let lease: Int32
    init(directory: URL, lease: Int32, event: @escaping @Sendable () -> Void) throws {
        let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CLIError(code: .io, message: "Cannot monitor CLI requests.") }
        self.descriptor = descriptor; self.lease = lease
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .global(qos: .utility))
        source.setEventHandler(handler: event)
        source.setCancelHandler { Darwin.close(descriptor); Darwin.close(lease) }
        source.resume()
    }
    func cancelAndWait() async {
        let descriptor = descriptor, lease = lease
        await withCheckedContinuation { continuation in
            source.setCancelHandler { Darwin.close(descriptor); Darwin.close(lease); continuation.resume() }
            source.cancel()
        }
    }
    deinit { source.cancel() }
}
