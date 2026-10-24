import Darwin
import Foundation

/// The app and bundled CLI exchange bounded, owner-only files inside one application-specific
/// mailbox. POSIX descriptors reject symlink leaves and retain the file being read even if its
/// name changes. Atomic publication means a watcher never observes a half-written JSON request.
nonisolated enum CLIFileIO {
    static func directory(appName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            .appendingPathComponent(appName).appendingPathComponent("Automation")
    }
    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw CLIError(code: .io, message: "The CLI mailbox must be a private directory owned by this user.")
        }
    }
    static func read(_ url: URL, maximum: Int = CLIInputPolicy.maximumBytes) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CLIError(code: .io, message: "Cannot read the requested file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= maximum else { throw CLIError.invalid("Expected a regular file within the byte limit.") }
        var data = Data()
        while let bytes = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)), !bytes.isEmpty {
            data.append(bytes)
            guard data.count <= maximum else { throw CLIError.invalid("File exceeds the byte limit.") }
        }
        return data
    }
    static func publish(_ data: Data, to destination: URL) throws {
        guard data.count <= CLIInputPolicy.maximumBytes else { throw CLIError.invalid("Response or request exceeds 32 MiB.") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".cli-" + UUID().uuidString)
        let descriptor = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw CLIError(code: .io, message: "Cannot stage a CLI message.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: staging) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard Darwin.link(staging.path, destination.path) == 0 else {
            throw CLIError(code: .io, message: "Cannot publish the CLI message.")
        }
    }
}
