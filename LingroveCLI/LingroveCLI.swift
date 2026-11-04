import AppKit
import Foundation
import MachO

/// A short-lived local client. The containing app chooses the Dev/production identity, so the
/// CLI never guesses a database path. Only explicitly named image files are read before sending
/// a bounded request to the app's owner-only mailbox; stdout stays machine-readable.
@main
struct LingroveCLI {
    @MainActor static func main() async {
        // C exit does not unwind Swift defers. Return through run() first so every consumed
        // reply and unclaimed request is removed before terminating the command process.
        let code = await run(); exit(code)
    }

    @MainActor private static func run() async -> Int32 {
        var requestID = UUID()
        do {
            let arguments = try CLIArguments(Array(CommandLine.arguments.dropFirst()))
            switch arguments.mode {
            case .help: print(CLIArguments.help); return 0
            case .version:
                let identity = CLIServiceIdentity(appURL: try application(nil))
                print("lingrove CLI \(CLIServiceIdentity.clientVersion) (protocol \(identity.protocolVersion), batch 1/2, capture 1)")
                print("app \(identity.appVersion) build \(identity.appBuild) at \(identity.appPath)")
                print("capabilities: " + identity.capabilities.joined(separator: ", "))
                return 0
            case .schema: print(CLIInputSchema.json); return 0
            case .captureSchema:
                let data = try JSONSerialization.data(withJSONObject: CLICaptureContract.schema, options: [.prettyPrinted, .sortedKeys])
                try write(data); return 0
            case .request: break
            }
            let appURL = try application(arguments.appPath)
            guard let bundle = Bundle(url: appURL), let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                  !name.isEmpty, !name.contains("/"), name != ".", name != "..", name.utf8.count <= 128 else {
                throw CLIError(code: .unavailable, message: "Cannot identify the containing app. Pass --app APP_PATH.")
            }
            let root = CLIFileIO.directory(appName: name)
            try await launchIfNeeded(arguments, appURL: appURL, bundle: bundle)
            var hello = CLIRequest(command: .hello)
            hello.expiresAt = Date().addingTimeInterval(arguments.timeout)
            let greeting = try await exchange(hello, root: root)
            guard greeting.ok, let server = greeting.server else {
                throw CLIError(code: .unavailable, message: "CLI/app handshake unsupported. " +
                    "Update the app and install its bundled CLI; no material was sent.")
            }
            try server.validate(appURL: appURL)
            var request = arguments.request; requestID = request.id
            request.serverInstanceID = server.instanceID
            request.targetAppPath = server.appPath
            if let input = arguments.inputPath { request.batch = try readBatch(input, capture: arguments.captureInput) }
            request.expiresAt = Date().addingTimeInterval(arguments.timeout)
            let reply = try await exchange(request, root: root)
            guard reply.server?.instanceID == server.instanceID else {
                throw CLIError(code: .unavailable, message: "CLI serving instance changed. " +
                    "Retry with the same key and material.")
            }
            try write(JSONEncoder().encode(reply))
            return reply.ok ? 0 : (reply.error?.exitCode ?? 7)
        } catch let error as CLIError {
            try? write(JSONEncoder().encode(CLIReply.failure(requestID, error))); return error.exitCode
        } catch {
            try? write(JSONEncoder().encode(CLIReply.failure(requestID, .init(code: .io, message: "Local CLI operation failed.")))); return 7
        }
    }

    /// Handshake and business requests share bounded transport, but only the latter carry
    /// material. An older server can reject the handshake without ever receiving a write.
    private static func exchange(_ request: CLIRequest, root: URL) async throws -> CLIReply {
        try CLIFileIO.ensureDirectory(root)
        for part in ["requests", "replies"] { try CLIFileIO.ensureDirectory(root.appendingPathComponent(part)) }
        let filename = request.id.uuidString + ".json"
        let pending = root.appendingPathComponent("requests").appendingPathComponent(filename)
        let response = root.appendingPathComponent("replies").appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: pending); try? FileManager.default.removeItem(at: response) }
        try CLIFileIO.publish(JSONEncoder().encode(request), to: pending)
        while Date() < request.expiresAt {
            if FileManager.default.fileExists(atPath: response.path) {
                let reply = try JSONDecoder().decode(CLIReply.self, from: CLIFileIO.read(response))
                guard reply.requestID == request.id else { throw CLIError(code: .io, message: "CLI response identity mismatch.") }
                guard reply.version == CLIServiceIdentity.protocolVersion else {
                    throw CLIError(code: .unavailable, message: "CLI/app protocol mismatch. " +
                        "Update the app and its CLI; do not remove notebookScope.")
                }
                return reply
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let message = request.command == .hello ? "CLI handshake timed out; no material was sent. Check the selected running app." :
            "Timed out. A write may already be committed; retry with the same key and content."
        throw CLIError(code: .timeout, message: message)
    }

    @MainActor private static func launchIfNeeded(_ arguments: CLIArguments, appURL: URL, bundle: Bundle) async throws {
        guard arguments.launch else { return }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundle.bundleIdentifier ?? "")
        if instances.contains(where: { $0.bundleURL?.resolvingSymlinksInPath() == appURL.resolvingSymlinksInPath() }) { return }
        // Starting an older copy beside an existing mailbox owner cannot select that copy.
        // Fail early instead of launching another app that competes for the same notebook.
        guard instances.isEmpty else {
            throw CLIError(code: .unavailable, message: "Another installation of this app is running. " +
                "Use its bundled CLI or update the CLI link in that app's settings.")
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        configuration.arguments = ["-lingrove-cli"]
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch { throw CLIError(code: .unavailable, message: "Cannot launch Lingrove. Open the selected app and retry.") }
    }

    /// Input IO starts only after a successful handshake. File-relative images and stdin use
    /// the same validated batch model; neither path can bypass scope or byte-limit checks.
    private static func readBatch(_ input: String, capture: Bool) throws -> CLIBatch {
        let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        let bytes: Data
        if input == "-" {
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount:
                min(65_536, CLIInputPolicy.maximumBytes + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= CLIInputPolicy.maximumBytes else { throw CLIError.invalid("Input exceeds 32 MiB.") }
            }
            bytes = data
        } else { bytes = try CLIFileIO.read(url) }
        var batch = try capture ? CLICaptureContract.decode(bytes) : CLIInputPolicy.decode(bytes)
        let base = input == "-" ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath) : url.deletingLastPathComponent()
        try attachImages(&batch, relativeTo: base)
        return batch
    }

    private static func write(_ data: Data) throws { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }

    private static func application(_ override: String?) throws -> URL {
        if let override {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        // argv[0] may be a PATH lookup or symlink. dyld knows the actual executable even when
        // launched through ~/.local/bin; resolve it before walking out of Contents/Helpers.
        var size: UInt32 = 0; _ = _NSGetExecutablePath(nil, &size)
        var bytes = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&bytes, &size) == 0 else {
            throw CLIError(code: .unavailable, message: "Cannot locate the CLI executable.")
        }
        return URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func attachImages(_ batch: inout CLIBatch, relativeTo base: URL) throws {
        var total = 0
        func resolve(_ values: [CLIBlock]?) throws -> [CLIBlock]? {
            guard var values else { return nil }
            for index in values.indices {
                guard let image = values[index].image else { continue }
                guard let path = image.path, !path.isEmpty, image.data == nil else { throw CLIError.invalid("An image needs a local path.") }
                let expanded = (path as NSString).expandingTildeInPath
                let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
                let data = try CLIFileIO.read(url, maximum: 16 * 1_024 * 1_024)
                total += data.count
                guard total <= 16 * 1_024 * 1_024 else { throw CLIError.invalid("Batch images exceed 16 MiB.") }
                values[index].image?.path = nil; values[index].image?.data = data
            }
            return values
        }
        for index in batch.operations.indices {
            // A local value avoids overlapping read/write access through optional chaining
            // into the same array while the resolver borrows its existing content.
            var operation = batch.operations[index]
            if var add = operation.add { add.content = try resolve(add.content); operation.add = add }
            if var append = operation.append { append.content = try resolve(append.content); operation.append = append }
            batch.operations[index] = operation
        }
    }
}
