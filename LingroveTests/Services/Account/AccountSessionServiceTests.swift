import Foundation
import Testing
@testable import Lingrove

/// Focused lifecycle scenarios protect the account boundary without launching local inference,
/// AX monitors, mobile simulators, or an external mailbox.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct AccountSessionServiceTests {
    @Test
    func untouchedAndConfiguredSignedOutLaunchesDoNotContactAnyService() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        fixture.service.start()
        #expect(fixture.service.state == .unconfigured)
        fixture.configure()
        fixture.service.shutdown()
        fixture.service.start()
        await Task.yield()
        #expect(fixture.service.state == .signedOut)
        #expect(fixture.client.sends == 0 && fixture.client.identities == 0 && fixture.client.refreshes == 0)
    }

    @Test
    func invalidAndExpiredCodesCanResendAndCancelWithoutRetainingCredentials() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        fixture.configure()
        fixture.service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { fixture.service.state == .awaitingCode }
        fixture.client.failure = .invalidCode
        fixture.service.submitCode("00000000")
        try await accountEventually { fixture.service.issue == .invalidCode }
        #expect(fixture.service.codePrompt?.isExpired == false)
        fixture.client.failure = .codeExpired
        fixture.service.submitCode("12345678")
        try await accountEventually { fixture.service.codePrompt?.isExpired == true }
        fixture.client.failure = nil
        fixture.service.resendCode()
        try await accountEventually { fixture.client.sends == 2 && fixture.service.state == .awaitingCode }
        #expect(fixture.service.codePrompt?.isExpired == false)
        fixture.service.cancelSignIn()
        #expect(fixture.service.state == .signedOut && fixture.service.codePrompt == nil)
        #expect(fixture.credentials.value == nil)
        #expect(try fixture.settings.load()?.allowsSessionRestore == false)
    }

    @Test
    func cancelledCodeRequestAndOldVerificationCannotReactivateAfterLogoutOrServiceChange() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        fixture.configure()
        fixture.client.holdSend = true
        fixture.service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { fixture.client.sendReply != nil }
        fixture.service.cancelSignIn()
        fixture.client.sendReply?.resume(returning: .challenge(AccountTestClient.challenge))
        fixture.client.sendReply = nil
        await Task.yield()
        #expect(fixture.service.state == .signedOut && fixture.service.codePrompt == nil)
        fixture.client.holdSend = false
        fixture.service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { fixture.service.state == .awaitingCode }
        fixture.client.holdVerify = true
        fixture.service.submitCode("12345678")
        try await accountEventually { fixture.client.verifyReply != nil }
        fixture.service.signOut()
        fixture.service.configure(api: "https://other.example.invalid/v1", auth: "https://auth.other.example.invalid")
        fixture.client.verifyReply?.resume(returning: AccountTestClient.tokens)
        fixture.client.verifyReply = nil
        await Task.yield()
        #expect(fixture.service.state == .signedOut)
        #expect(fixture.credentials.value == nil && fixture.client.identities == 0)
    }

    @Test
    func refreshIsSingleFlightAndPersistsRotationBeforePublishingIdentity() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        fixture.configure()
        try fixture.seed()
        fixture.client.holdRefresh = true
        let first = Task { try await fixture.service.confirmedIdentity(forceRefresh: true) }
        try await accountEventually { fixture.client.refreshReply != nil }
        let second = Task { try await fixture.service.confirmedIdentity(forceRefresh: true) }
        let cancelledConsumer = Task { try await fixture.service.confirmedIdentity(forceRefresh: true) }
        await Task.yield()
        cancelledConsumer.cancel()
        #expect(fixture.client.refreshes == 1)
        fixture.client.refreshReply?.resume(returning: AccountTestClient.rotated)
        fixture.client.refreshReply = nil
        #expect(try await first.value == fixture.client.currentIdentity)
        #expect(try await second.value == fixture.client.currentIdentity)
        await #expect(throws: CancellationError.self) { try await cancelledConsumer.value }
        #expect(fixture.client.identities == 1)
        #expect(fixture.credentials.saved.last?.credentials.refreshToken == "synthetic-rotated")
        #expect(fixture.service.state == .signedIn(fixture.client.currentIdentity))
    }

    @Test
    func lateIdentityConfirmationCannotRewriteCredentialsAfterCancel() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        fixture.configure()
        fixture.service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { fixture.service.state == .awaitingCode }
        fixture.client.holdIdentity = true
        fixture.service.submitCode("12345678")
        try await accountEventually { fixture.client.identityReply != nil }
        #expect(fixture.credentials.value?.identity == nil)
        #expect(fixture.credentials.value != nil, "Pending credentials let an offline /me retry recover a consumed OTP")
        fixture.service.cancelSignIn()
        fixture.client.identityReply?.resume(returning: fixture.client.currentIdentity)
        fixture.client.identityReply = nil
        await Task.yield()
        #expect(fixture.service.state == .signedOut && fixture.credentials.value == nil)
        #expect(try fixture.settings.load()?.allowsSessionRestore == false)
    }

    @Test
    func failedOldCredentialDeletionKeepsItsScopeAvailableForRetry() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        fixture.credentials.failsClear = true
        #expect(!fixture.service.configure(api: "https://other.example.invalid/v1", auth: "https://auth.other.example.invalid"))
        #expect(fixture.service.configuration == fixture.configuration)
        #expect(fixture.service.issue == .secureStorage)
        #expect(try fixture.settings.load()?.allowsSessionRestore == false)
        #expect(!AccountConfigurationPolicy.matchesSavedConnection(api: "https://other.example.invalid/v1",
            auth: "https://auth.other.example.invalid", saved: fixture.service.configuration),
            "Authentication controls must stay disabled while the visible destination differs from the retained connection")
        #expect(!fixture.service.removeConfiguration())
        #expect(fixture.service.configuration == fixture.configuration)
        fixture.credentials.failsClear = false
        #expect(fixture.service.configure(api: "https://other.example.invalid/v1", auth: "https://auth.other.example.invalid"))
        #expect(fixture.credentials.value == nil && fixture.service.issue == nil)
        #expect(fixture.service.removeConfiguration())
        #expect(fixture.service.state == .unconfigured)
    }

    @Test
    func lateRefreshCannotUndoSignoutAndFailedKeychainClearCannotRestoreOnRestart() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        fixture.client.holdRefresh = true
        let work = Task { try? await fixture.service.confirmedIdentity(forceRefresh: true) }
        try await accountEventually { fixture.client.refreshReply != nil }
        fixture.credentials.failsClear = true
        fixture.service.signOut()
        #expect(fixture.service.issue == .secureStorage)
        fixture.client.refreshReply?.resume(returning: AccountTestClient.rotated)
        fixture.client.refreshReply = nil
        _ = await work.value
        #expect(fixture.service.state == .signedOut)
        #expect(fixture.credentials.saved.last?.credentials.refreshToken == "synthetic-refresh")
        let reopened = AccountSessionService(client: fixture.client, credentials: fixture.credentials, settings: fixture.settings)
        reopened.start()
        defer { reopened.shutdown() }
        #expect(reopened.state == .signedOut)
        #expect(fixture.client.identities == 1)
    }

    @Test
    func offlineRestorationRetainsSessionButServerInvalidationAndChangedIdentityFailClosed() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        fixture.configure()
        try fixture.seed()
        fixture.client.failure = .network
        fixture.service.start()
        try await accountEventually { fixture.service.state == .offline(fixture.client.currentIdentity) }
        #expect(fixture.credentials.value != nil)
        fixture.client.failure = nil
        fixture.service.retrySession()
        try await accountEventually { fixture.service.state == .signedIn(fixture.client.currentIdentity) }
        fixture.client.currentIdentity = AccountIdentity(userID: "unexpected-other-account", email: nil, canonicalAccountID: nil)
        _ = try? await fixture.service.confirmedIdentity(recheck: true)
        #expect(fixture.service.state == .credentialsInvalid)
        #expect(fixture.service.issue == .identityChanged && fixture.credentials.value == nil)
        try fixture.seed()
        fixture.client.failure = .credentialsInvalid
        fixture.service.retrySession()
        try await accountEventually { fixture.service.issue == .credentialsInvalid }
        #expect(fixture.service.state == .credentialsInvalid)
        #expect(fixture.credentials.value == nil)
    }
}
