import Foundation
import LingroveNotebook

/// A mailbox lease owns one identity for its lifetime. The client learns it before sending
/// material, then pins every request to that instance and app path. Notebook scope remains a
/// separate archive concern: matching a process must never authorize a different notebook.
nonisolated struct CLIServiceIdentity: Codable, Equatable, Sendable {
    static let protocolVersion = 3
    static let clientVersion = 5
    static let capabilities = ["notebookScope", "captureCategories", "categorySummary", "categoryReceipts",
        "canonicalSenses", "senseImages", "senseEdits", "changePreview", "batchSenseReads"]

    var instanceID = UUID()
    var processID: Int32
    var appPath: String
    var bundleIdentifier: String
    var appVersion: String
    var appBuild: String
    var protocolVersion: Int
    var capabilities: [String]

    init(appURL: URL = Bundle.main.bundleURL) {
        let bundle = Bundle(url: appURL)
        processID = ProcessInfo.processInfo.processIdentifier
        appPath = appURL.resolvingSymlinksInPath().path
        bundleIdentifier = bundle?.bundleIdentifier ?? "unknown"
        appVersion = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        appBuild = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        protocolVersion = Self.protocolVersion
        capabilities = Self.capabilities
    }

    func validate(appURL: URL) throws {
        guard appPath == appURL.resolvingSymlinksInPath().path else {
            throw CLIError(code: .unavailable, message: "CLI destination mismatch. Mailbox is served by " + appPath +
                "; selected " + appURL.path + ". Use the serving app's bundled CLI or update the CLI installation.")
        }
        guard protocolVersion == Self.protocolVersion, Set(Self.capabilities).isSubset(of: Set(capabilities)) else {
            throw CLIError(code: .unavailable, message: "CLI/app capabilities differ. " +
                "Update the app and install its bundled CLI; do not remove notebookScope.")
        }
    }

    func validate(_ request: CLIRequest) throws {
        guard request.version == Self.protocolVersion else {
            throw CLIError(code: .unavailable, message: "Unsupported CLI protocol. " +
                "Install the CLI from this app's Settings > General > Command-line tools.")
        }
        guard request.command == .hello ||
                (request.serverInstanceID == instanceID && request.targetAppPath == appPath) else {
            throw CLIError(code: .unavailable, message: "CLI serving instance changed or handshake is missing. " +
                "Reconnect with the same write key and material.")
        }
    }
}
