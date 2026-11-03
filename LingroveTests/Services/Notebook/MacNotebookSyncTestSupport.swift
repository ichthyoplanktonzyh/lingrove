import CryptoKit
import Foundation
import LingroveCloud
import LingroveNotebook
import LingroveNotebookEngine
import Testing
@testable import Lingrove

/// Each scenario owns one real loopback process, private Keychain namespace, preferences domain,
/// and primary SQLite/media directory. No installed app state, system grants or mailbox is used.
@MainActor
final class MacNotebookSyncFixture {
    let server: MacNotebookLoopback
    let directory: URL
    let suite = "lingrove.mac-sync.synthetic." + UUID().uuidString
    let defaults: UserDefaults
    let credentials: KeychainAccountCredentialStore
    let settings: AccountConfigurationStore
    var account: AccountSessionService
    var repository: MacNotebookRepository
    var sync: MacNotebookSyncController

    init() throws {
        server = try MacNotebookLoopback()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-mac-sync-" + UUID().uuidString)
        defaults = try #require(UserDefaults(suiteName: suite))
        credentials = KeychainAccountCredentialStore(bundleIdentifier: suite, namespace: "notebook-sync-tests")
        settings = AccountConfigurationStore(defaults: defaults)
        account = AccountSessionService(client: AccountAPIClient(), credentials: credentials, settings: settings)
        repository = try MacNotebookRepository(databaseURL: directory.appendingPathComponent("primary.sqlite"),
            mediaDirectoryURL: directory.appendingPathComponent("media"))
        sync = MacNotebookSyncController(repository: repository, account: account,
            consentStore: MacNotebookSyncConsentStore(defaults: defaults))
    }
    func start() { account.start(); sync.start() }
    func signIn(_ name: String = "a") async throws {
        account.configure(api: server.configuration.apiBaseURL.absoluteString, auth: server.configuration.authBaseURL.absoluteString)
        account.requestCode(email: name + "@example.invalid")
        try await syncEventually { self.account.state == .awaitingCode }
        account.submitCode("12345678")
        try await syncEventually { if case .signedIn = self.account.state { return !self.sync.workspaces.isEmpty }; return false }
    }
    func connect() async throws {
        let workspace = try #require(sync.workspaces.first)
        sync.chooseWorkspace(workspace.id)
        try await syncEventually { !self.sync.isChoosingWorkspace && self.sync.selectedWorkspace?.id == workspace.id }
    }
    func restart() throws {
        sync.shutdown(); account.shutdown(); try repository.shutdown()
        account = AccountSessionService(client: AccountAPIClient(), credentials: credentials, settings: settings)
        repository = try MacNotebookRepository(databaseURL: directory.appendingPathComponent("primary.sqlite"),
            mediaDirectoryURL: directory.appendingPathComponent("media"))
        sync = MacNotebookSyncController(repository: repository, account: account,
            consentStore: MacNotebookSyncConsentStore(defaults: defaults))
        start()
    }
    func cleanup() {
        sync.shutdown(); account.shutdown(); try? repository.shutdown()
        try? credentials.clear(configuration: server.configuration)
        defaults.removePersistentDomain(forName: suite)
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    @discardableResult func saveLocal(withReview: Bool = false) throws -> LingroveNotebookSnapshot {
        let date = Date()
        let image = Self.image
        let document = VocabularyDocument(entries: [.init(id: UUID(), expression: "synthetic local", dictionaryForm: "synthetic local",
            language: .english, kind: .expression, senses: [.init(id: UUID(), meaning: "saved for a test", meaningLanguage: .english,
                meaningOrigin: .user, isSavedWithoutContext: true, content: [.init(content: .image(image, caption: "fixture"))],
                createdAt: date, updatedAt: date)], createdAt: date, updatedAt: date)])
        let saved = try repository.engine.saveLingroveNotebook(document, basedOn: repository.snapshot(), images: [image.filename: Self.png])
        if withReview {
            let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved,
                selection: .init(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id))
            let enrollment = try #require(try repository.engine.enrollNotebookSenses([draft], basedOn: saved).first)
            let exercise = try #require(try repository.engine.lingroveNotebookReviewStore.exercises(enrollment).first)
            _ = try repository.engine.submitNotebookRating(.init(cardId: exercise.cardId, rating: .good,
                reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "Asia/Shanghai"), basedOn: saved)
        }
        repository.publishChange()
        return saved
    }
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    static var image: VocabularyImageReference {
        .init(digest: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(), width: 1, height: 1, byteCount: png.count)
    }
}

@MainActor
final class MacNotebookLoopback {
    let process = Process()
    let baseURL: URL
    let configuration: AccountServiceConfiguration
    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/tests/fixtures/mac_notebook_sync_server.py").path]
        let output = Pipe()
        process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
        let value = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerPort = Int(ProcessInfo.processInfo.environment["LINGROVE_MAC_SYNC_TEST_PORT_MIN"] ?? "19480") ?? 19480
        guard let port = Int(value), (lowerPort...(lowerPort + 2)).contains(port), let url = URL(string: "http://127.0.0.1:\(port)") else {
            if process.isRunning { process.terminate() }
            throw AccountIssue.invalidConfiguration
        }
        baseURL = url
        configuration = try AccountConfigurationPolicy.configuration(api: url.absoluteString + "/api", auth: url.absoluteString + "/auth")
    }
    func mode(_ value: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("fixture/mode"))
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(["mode": value])
        _ = try await URLSession.shared.data(for: request)
    }
    func waitForRequest(suffix: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !stats().paths.contains(where: { $0.hasSuffix(suffix) }) {
            guard ContinuousClock.now < deadline else { throw MacNotebookTestTimeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    struct Stats: Codable { let paths: [String]; let checks: [Bool]; let refreshes: Int; let groups: Int; let images: Int }
    func stats() async throws -> Stats {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("fixture/stats"))
        return try JSONDecoder().decode(Stats.self, from: data)
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
}

@MainActor
func syncEventually(_ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while try !predicate() {
        guard ContinuousClock.now < deadline else { throw MacNotebookTestTimeout() }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private struct MacNotebookTestTimeout: Error {}
