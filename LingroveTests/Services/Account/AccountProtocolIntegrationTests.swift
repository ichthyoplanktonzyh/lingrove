import Foundation
import Testing
@testable import Lingrove

/// Real URLSession and private Keychain checks keep protocol correctness separate from state
/// machine fakes. Every identity, token, preference domain and server process is synthetic.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct AccountProtocolIntegrationTests {
    @Test
    func nativeOTPContractChecksIdentityAndRejectsErrorBodiesAndRedirects() async throws {
        let server = try AccountLoopbackServer()
        defer { server.stop() }
        let client = AccountAPIClient()
        let result = try await client.sendCode(email: "synthetic@example.invalid", configuration: server.configuration)
        guard case .challenge(let challenge) = result else {
            Issue.record("Expected native OTP challenge")
            return
        }
        await #expect(throws: AccountIssue.invalidCode) {
            try await client.verifyCode("00000000", challenge: challenge, configuration: server.configuration)
        }
        await #expect(throws: AccountIssue.codeExpired) {
            try await client.verifyCode("99999999", challenge: challenge, configuration: server.configuration)
        }
        await #expect(throws: AccountIssue.codeConsumed) {
            try await client.verifyCode("88888888", challenge: challenge, configuration: server.configuration)
        }
        let credentials = try await client.verifyCode("12345678", challenge: challenge, configuration: server.configuration)
        let identity = try await client.identity(idToken: credentials.idToken, configuration: server.configuration)
        #expect(identity.userID == "server-account-surrogate", "Identity comes from /me, not a JWT subject")
        await #expect(throws: AccountIssue.invalidResponse) {
            try await client.sendCode(email: "redirect@example.invalid", configuration: server.configuration)
        }
        await #expect(throws: AccountIssue.invalidResponse) {
            try await client.sendCode(email: "oversized@example.invalid", configuration: server.configuration)
        }
        try await server.mode("malformed")
        await #expect(throws: AccountIssue.invalidResponse) {
            try await client.identity(idToken: credentials.idToken, configuration: server.configuration)
        }
        let stats = try await server.stats()
        #expect(stats.checks.allSatisfy { $0 })
        #expect(stats.counts["/forbidden-redirect"] == nil)
        #expect(!AccountPresentation.message(.invalidCode).contains("PRIVATE_BODY"))
    }

    @Test
    func privateKeychainReopensAndRotatesAcrossServiceRestartsWithoutTouchingOtherScopes() async throws {
        let server = try AccountLoopbackServer()
        defer { server.stop() }
        let suite = "lingrove.synthetic.keychain.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeychainAccountCredentialStore(bundleIdentifier: suite, namespace: "account-integration")
        let isolated = KeychainAccountCredentialStore(bundleIdentifier: suite + ".dev", namespace: "account-integration")
        defer { try? store.clear(configuration: server.configuration); try? isolated.clear(configuration: server.configuration) }
        // Probe the actual Keychain boundary directly so a signing/entitlement failure reports
        // its OSStatus rather than being confused with a later asynchronous UI-state timeout.
        try store.save(AccountStoredSession(configuration: server.configuration,
            credentials: AccountTestClient.tokens, identity: nil))
        #expect(try store.load(configuration: server.configuration) != nil)
        try store.clear(configuration: server.configuration)
        let settings = AccountConfigurationStore(defaults: defaults)
        let service = AccountSessionService(client: AccountAPIClient(), credentials: store, settings: settings)
        defer { service.shutdown() }
        service.configure(api: server.configuration.apiBaseURL.absoluteString, auth: server.configuration.authBaseURL.absoluteString)
        service.requestCode(email: " Synthetic@Example.invalid ")
        try await accountEventually { service.state == .awaitingCode }
        service.submitCode("12345678")
        try await accountEventually { if case .signedIn = service.state { return true }; return false }
        let loaded = try store.load(configuration: server.configuration)
        let item = try #require(loaded)
        #expect(item.identity?.userID == "server-account-surrogate")
        #expect(try isolated.load(configuration: server.configuration) == nil)
        let other = try AccountConfigurationPolicy.configuration(api: "https://other.example.invalid/v1", auth: "https://other.example.invalid/auth")
        #expect(try store.load(configuration: other) == nil)
        service.shutdown()

        let reopenedStore = KeychainAccountCredentialStore(bundleIdentifier: suite, namespace: "account-integration")
        let reopened = AccountSessionService(client: AccountAPIClient(), credentials: reopenedStore, settings: settings)
        defer { reopened.shutdown() }
        reopened.start()
        try await accountEventually { if case .signedIn = reopened.state { return true }; return false }
        _ = try await reopened.confirmedIdentity(forceRefresh: true)
        #expect(try reopenedStore.load(configuration: server.configuration)?.credentials.refreshToken == "synthetic-refresh-rotated")
        _ = try await reopened.confirmedIdentity(forceRefresh: true)
        #expect(try reopenedStore.load(configuration: server.configuration)?.credentials.refreshToken == "synthetic-refresh-rotated")
        try await server.mode("offline")
        _ = try? await reopened.confirmedIdentity(recheck: true)
        #expect(reopened.issue == .serviceUnavailable)
        #expect(try reopenedStore.load(configuration: server.configuration) != nil)
        reopened.shutdown()
        try await server.mode("online")
        let afterOffline = AccountSessionService(client: AccountAPIClient(), credentials: reopenedStore, settings: settings)
        defer { afterOffline.shutdown() }
        afterOffline.start()
        try await accountEventually { if case .signedIn = afterOffline.state { return true }; return false }
        afterOffline.signOut()
        #expect(try reopenedStore.load(configuration: server.configuration) == nil)
        #expect(try settings.load()?.allowsSessionRestore == false)
        let preferenceRecord = try #require(defaults.data(forKey: "lingroveAccountConnectionV1"))
        let text = String(decoding: preferenceRecord, as: UTF8.self)
        #expect(!text.contains("synthetic-refresh") && !text.contains("synthetic-id"))
        let stats = try await server.stats()
        #expect(stats.checks.allSatisfy { $0 })
        #expect(stats.counts["/auth/api/refresh-token"] == 2)
    }
}
