import Foundation
import Testing
@testable import Lingrove

/// Synthetic values and controllable network completions exercise the service's transaction
/// boundaries. Held continuations intentionally ignore cancellation to replay late OS callbacks.
@MainActor
final class AccountTestClient: AccountAuthenticating {
    var sends = 0
    var verifies = 0
    var refreshes = 0
    var identities = 0
    var holdSend = false
    var holdVerify = false
    var holdRefresh = false
    var holdIdentity = false
    var failure: AccountIssue?
    var currentIdentity = AccountIdentity(userID: "synthetic-user", email: "synthetic@example.invalid", canonicalAccountID: nil)
    var sendReply: CheckedContinuation<AccountSendCodeResult, Error>?
    var verifyReply: CheckedContinuation<AccountCredentials, Error>?
    var refreshReply: CheckedContinuation<AccountCredentials, Error>?
    var identityReply: CheckedContinuation<AccountIdentity, Error>?

    static var tokens: AccountCredentials {
        AccountCredentials(idToken: "synthetic-id", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600))
    }
    static var rotated: AccountCredentials {
        AccountCredentials(idToken: "synthetic-new-id", refreshToken: "synthetic-rotated", expiresAt: Date().addingTimeInterval(3600))
    }
    static var challenge: AccountOTPChallenge {
        AccountOTPChallenge(email: "synthetic@example.invalid", csrfToken: "csrf", otpSessionToken: "otp",
            expiresAt: Date().addingTimeInterval(180))
    }

    func sendCode(email: String, configuration: AccountServiceConfiguration) async throws -> AccountSendCodeResult {
        sends += 1
        if holdSend { return try await withCheckedThrowingContinuation { sendReply = $0 } }
        if let failure { throw failure }
        return .challenge(Self.challenge)
    }
    func verifyCode(_ code: String, challenge: AccountOTPChallenge,
                    configuration: AccountServiceConfiguration) async throws -> AccountCredentials {
        verifies += 1
        if holdVerify { return try await withCheckedThrowingContinuation { verifyReply = $0 } }
        if let failure { throw failure }
        return Self.tokens
    }
    func refresh(_ credentials: AccountCredentials, configuration: AccountServiceConfiguration) async throws -> AccountCredentials {
        refreshes += 1
        if holdRefresh { return try await withCheckedThrowingContinuation { refreshReply = $0 } }
        if let failure { throw failure }
        return Self.rotated
    }
    func identity(idToken: String, configuration: AccountServiceConfiguration) async throws -> AccountIdentity {
        identities += 1
        if holdIdentity { return try await withCheckedThrowingContinuation { identityReply = $0 } }
        if let failure { throw failure }
        return currentIdentity
    }
}

/// Most lifecycle tests isolate storage in memory; the loopback integration test below separately
/// uses real private Keychain. Failure injection proves logout stays closed if deletion fails.
@MainActor
final class AccountTestCredentials: AccountCredentialStoring {
    var value: AccountStoredSession?
    var saved: [AccountStoredSession] = []
    var failsClear = false
    func load(configuration: AccountServiceConfiguration) throws -> AccountStoredSession? {
        value?.configuration == configuration ? value : nil
    }
    func save(_ session: AccountStoredSession) throws { value = session; saved.append(session) }
    func clear(configuration: AccountServiceConfiguration) throws {
        if failsClear { throw AccountIssue.secureStorage }
        if value?.configuration == configuration { value = nil }
    }
}

/// Each fixture owns a private preferences domain and one service. Cleanup is explicit because
/// Swift deinitialization is not a reliable actor-isolated lifecycle callback.
@MainActor
final class AccountTestFixture {
    let suite = "lingrove.synthetic-account.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AccountConfigurationStore
    let client = AccountTestClient()
    let credentials = AccountTestCredentials()
    let service: AccountSessionService
    let configuration: AccountServiceConfiguration

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AccountConfigurationStore(defaults: defaults)
        configuration = try AccountConfigurationPolicy.configuration(api: "http://127.0.0.1:18980/v1", auth: "http://127.0.0.1:18981")
        service = AccountSessionService(client: client, credentials: credentials, settings: settings)
    }
    func configure() { service.configure(api: configuration.apiBaseURL.absoluteString, auth: configuration.authBaseURL.absoluteString) }
    func seed() throws {
        settings.save(configuration, allowsSessionRestore: true)
        try credentials.save(AccountStoredSession(configuration: configuration,
            credentials: AccountTestClient.tokens, identity: client.currentIdentity))
    }
    func cleanup() { service.shutdown(); defaults.removePersistentDomain(forName: suite) }
    func signIn() async throws {
        configure()
        service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { self.service.state == .awaitingCode }
        service.submitCode("12345678")
        try await accountEventually { self.service.state == .signedIn(self.client.currentIdentity) }
    }
}

/// Bounded event waiting replaces fixed delays in race tests; timeout is an assertion failure,
/// not a pass or an invitation to keep extending automation waits.
@MainActor
func accountEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw AccountTestTimeout() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct AccountTestTimeout: Error {}

/// The owned subprocess binds a fresh loopback port and exits at the end of its test. Neither the
/// production auth host nor the main thread's mobile fixture ports are used.
@MainActor
final class AccountLoopbackServer {
    let process = Process()
    let configuration: AccountServiceConfiguration
    let baseURL: URL

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/tests/fixtures/account_auth_server.py").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.availableData
        let envelope = try JSONDecoder().decode(Port.self, from: data)
        baseURL = try #require(URL(string: "http://127.0.0.1:\(envelope.port)"))
        configuration = try AccountConfigurationPolicy.configuration(
            api: baseURL.absoluteString + "/api/v1", auth: baseURL.absoluteString + "/auth")
    }

    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }

    func mode(_ mode: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("fixture/mode"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["mode": mode])
        _ = try await URLSession.shared.data(for: request)
    }

    func stats() async throws -> Stats {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("fixture/stats"))
        return try JSONDecoder().decode(Stats.self, from: data)
    }

    private struct Port: Decodable { let port: Int }
    struct Stats: Decodable { let counts: [String: Int]; let checks: [Bool] }
}
