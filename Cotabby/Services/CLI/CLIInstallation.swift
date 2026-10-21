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
        return URL(fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent()).standardizedFileURL == executable.standardizedFileURL
            && FileManager.default.isExecutableFile(atPath: executable.path)
    }

    func install() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CLIError(code: .unavailable, message: "Bundled CLI executable is missing.") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFLNK, isInstalled() else {
                throw CLIError(code: .conflict, message: "Another command already exists at the installation path.")
            }
            return
        }
        // Exclusive publication keeps a simultaneously created unrelated command intact.
        guard symlink(executable.path, destination.path) == 0 else { throw CLIError(code: .io, message: "Cannot install the CLI link.") }
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
        #if COTABBY_DEV
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
        do { try await worker.install(); await refresh() }
        catch let failure as CLIError { error = failure.message }
        catch { self.error = "Cannot install the CLI link." }
    }
}
