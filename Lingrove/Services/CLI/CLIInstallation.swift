import Combine
import Darwin
import Foundation

/// File operations stay on this actor. Installation creates a user-owned PATH symlink, without
/// changing shell profiles or needing administrator access. An unrelated existing command is
/// never replaced. Dev and production use different names and keep their own mailbox identities.
actor CLIInstallation {
    let executable: URL
    let destination: URL
    init(executable: URL, destination: URL) { self.executable = executable; self.destination = destination }

    func isInstalled() -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path) else { return false }
        let resolvedTarget = URL(fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent()).standardizedFileURL
        return resolvedTarget == executable.standardizedFileURL
            && FileManager.default.isExecutableFile(atPath: executable.path)
    }

    func install() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CLIError(code: .unavailable, message: "Bundled CLI executable is missing.")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFLNK, info.st_uid == getuid() else {
                throw CLIError(code: .conflict, message: "Another command already exists at the installation path.")
            }
            if isInstalled() { return }
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
                  Self.productIdentifier(for: URL(fileURLWithPath: target,
                    relativeTo: destination.deletingLastPathComponent()).standardizedFileURL) == Self.productIdentifier(for: executable),
                  Self.productIdentifier(for: executable) != nil else {
                throw CLIError(code: .conflict, message: "An unrelated or unverifiable link exists at the installation path.")
            }
            try replaceLink(observed: info)
            return
        }
        guard errno == ENOENT else {
            throw CLIError(code: .io, message: "Cannot inspect the CLI installation path.")
        }
        // Exclusive publication keeps a simultaneously created unrelated command intact.
        guard symlink(executable.path, destination.path) == 0 else { throw CLIError(code: .io, message: "Cannot install the CLI link.") }
    }

    /// Only the canonical helper inside the same product is replaceable. A similarly named
    /// user script, arbitrary symlink, or production/Dev cross-link is not an earlier install.
    private static func productIdentifier(for helper: URL) -> String? {
        let helper = helper.standardizedFileURL
        let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard helper == app.appendingPathComponent("Contents/Helpers/lingrove"),
              let identifier = Bundle(url: app)?.bundleIdentifier,
              ["io.ichthyoplanktonzyh.lingrove", "io.ichthyoplanktonzyh.lingrove.dev"].contains(identifier) else { return nil }
        return identifier
    }

    private func replaceLink(observed: stat) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".lingrove-install-" + UUID().uuidString)
        guard symlink(executable.path, staging.path) == 0 else {
            throw CLIError(code: .io, message: "Cannot stage the updated CLI link.")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        var current = stat()
        guard lstat(destination.path, &current) == 0, current.st_dev == observed.st_dev,
              current.st_ino == observed.st_ino, current.st_mode == observed.st_mode else {
            throw CLIError(code: .conflict, message: "CLI installation changed during update. Inspect the path and retry.")
        }
        // Publish the new target atomically, so a normal invocation never observes a missing
        // command between removing the old link and installing its replacement.
        guard rename(staging.path, destination.path) == 0 else {
            throw CLIError(code: .io, message: "Cannot update the CLI link.")
        }
    }
}

/// Settings observes this app-owned model; it does not create an installer in a view. The worker
/// owns file IO, while published status and errors are updated only on MainActor.
@MainActor final class CLIInstallationModel: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    let command: String
    let path: String
    private let worker: CLIInstallation

    init(bundle: Bundle = .main) {
        #if LINGROVE_DEV
        command = "lingrove-dev"
        #else
        command = (bundle.bundleIdentifier ?? "").hasSuffix(".dev") ? "lingrove-dev" : "lingrove"
        #endif
        let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/" + command)
        path = "~/.local/bin/" + command
        worker = CLIInstallation(executable: bundle.bundleURL.appendingPathComponent("Contents/Helpers/lingrove"), destination: destination)
    }
    func refresh() async { installed = await worker.isInstalled() }
    func install() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            try await worker.install()
            await refresh()
        } catch let failure as CLIError {
            error = failure.message
        } catch {
            self.error = "Cannot install the CLI link."
        }
    }
}
