import Foundation
import LingroveCloud
import Testing
@testable import Lingrove

/// Host defaults complement the unchanged shared session. Synthetic preferences and in-memory
/// credentials exercise precedence, explicit switches and logout without real service traffic.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct AccountDefaultConnectionTests {
    private var bundled: AccountServiceConfiguration {
        get throws {
            try AccountConfigurationPolicy.configuration(api: "https://api.example.invalid/v1", auth: "https://auth.example.invalid")
        }
    }

    @Test(arguments: [AccountBuildConfiguration.missing, .invalid])
    func unavailableBuildDefaultCannotSendOrRestore(_ build: AccountBuildConfiguration) async throws {
        let fixture = try AccountTestFixture(buildConfiguration: build)
        defer { fixture.cleanup() }
        fixture.service.start()
        fixture.service.requestCode(email: "synthetic@example.invalid")
        #expect(!fixture.service.useApplicationDefault())
        await Task.yield()
        #expect(fixture.service.configuration == nil && fixture.service.connectionSource == nil)
        #expect(fixture.service.state == .unconfigured && fixture.service.codePrompt == nil)
        #expect(fixture.client.sends == 0 && fixture.client.identities == 0 && fixture.client.refreshes == 0)
    }

    @Test func freshBuildDefaultNeedsNoURLInputAndDoesNotEnableRestore() async throws {
        let expected = try bundled
        let fixture = try AccountTestFixture(buildConfiguration: .available(expected))
        defer { fixture.cleanup() }
        fixture.service.start()
        await Task.yield()
        #expect(fixture.service.configuration == expected && fixture.service.connectionSource == .applicationDefault)
        #expect(fixture.service.state == .signedOut && !fixture.service.canUseApplicationDefault)
        #expect(try fixture.settings.load()?.allowsSessionRestore == false)
        #expect(fixture.client.sends == 0 && fixture.client.identities == 0)
        let draft = AccountSettingsNavigation()
        draft.reconcile(configuration: fixture.service.configuration)
        #expect(draft.matches(expected) && !draft.hasChanges(comparedWith: expected))
    }

    @Test func savedCustomWinsOverNewOrInvalidDefaultsAndResetIsExplicit() throws {
        let expected = try bundled
        let fixture = try AccountTestFixture(buildConfiguration: .available(expected))
        defer { fixture.cleanup() }
        fixture.configure()
        #expect(fixture.service.connectionSource == .custom && fixture.service.canUseApplicationDefault)
        let reopenedSettings = AccountConfigurationStore(defaults: fixture.defaults, buildConfiguration: .invalid)
        let reopened = AccountSessionService(client: fixture.client, credentials: fixture.credentials, settings: reopenedSettings)
        defer { reopened.shutdown() }
        reopened.start()
        #expect(reopened.configuration == fixture.configuration && reopened.connectionSource == .custom)
        #expect(!reopened.canUseApplicationDefault && !reopened.useApplicationDefault())
        #expect(fixture.service.useApplicationDefault())
        #expect(fixture.service.configuration == expected && fixture.service.connectionSource == .applicationDefault)
        #expect(try fixture.settings.load()?.configuration == expected)
        #expect(try fixture.settings.load()?.allowsSessionRestore == false)
        #expect(fixture.client.sends == 0 && fixture.client.identities == 0)
    }

    @Test func existingExplicitRecordKeepsCustomSourceAndRestorePermission() throws {
        let expected = try bundled
        let fixture = try AccountTestFixture(buildConfiguration: .available(expected))
        defer { fixture.cleanup() }
        let record = AccountConnectionRecord(configuration: fixture.configuration, allowsSessionRestore: false)
        fixture.defaults.set(try JSONEncoder().encode(record), forKey: "lingroveAccountConnectionV1")
        let reopened = AccountSessionService(client: fixture.client, credentials: fixture.credentials, settings: fixture.settings)
        defer { reopened.shutdown() }
        reopened.start()
        #expect(reopened.configuration == fixture.configuration && reopened.connectionSource == .custom)
        #expect(try fixture.settings.load()?.allowsSessionRestore == false)
        #expect(fixture.client.sends == 0 && fixture.client.identities == 0)
    }

    @Test func explicitlySavingTheBundledPairAsCustomKeepsThatChoice() throws {
        let expected = try bundled
        let fixture = try AccountTestFixture(buildConfiguration: .available(expected))
        defer { fixture.cleanup() }
        #expect(fixture.service.configure(api: expected.apiBaseURL.absoluteString, auth: expected.authBaseURL.absoluteString))
        #expect(fixture.service.connectionSource == .custom && fixture.service.canUseApplicationDefault)
        let store = AccountConfigurationStore(defaults: fixture.defaults, buildConfiguration: .available(fixture.configuration))
        let reopened = AccountSessionService(client: fixture.client, credentials: fixture.credentials, settings: store)
        defer { reopened.shutdown() }
        #expect(reopened.configuration == expected && reopened.connectionSource == .custom)
    }

    @Test func savedBundledPairIsPinnedAcrossReleasesUntilConfirmedReset() throws {
        let previous = try bundled
        let fixture = try AccountTestFixture(buildConfiguration: .available(previous))
        defer { fixture.cleanup() }
        let next = fixture.configuration
        let store = AccountConfigurationStore(defaults: fixture.defaults, buildConfiguration: .available(next))
        let reopened = AccountSessionService(client: fixture.client, credentials: fixture.credentials, settings: store)
        defer { reopened.shutdown() }
        #expect(reopened.configuration == previous && reopened.connectionSource == .applicationDefault)
        #expect(reopened.canUseApplicationDefault)
        #expect(reopened.useApplicationDefault())
        #expect(reopened.configuration == next)
        #expect(try store.load()?.allowsSessionRestore == false)
    }

    @Test func returningDuringResendRetiresItsLateChallenge() async throws {
        let fixture = try AccountTestFixture(buildConfiguration: .available(try bundled))
        defer { fixture.cleanup() }
        fixture.service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { fixture.service.state == .awaitingCode }
        fixture.client.holdSend = true
        fixture.service.resendCode()
        try await accountEventually { fixture.client.sendReply != nil }
        #expect(fixture.service.codePrompt == nil && fixture.service.state == .working(.sendingCode))
        fixture.service.cancelSignIn()
        fixture.client.sendReply?.resume(returning: .challenge(AccountTestClient.challenge))
        fixture.client.sendReply = nil
        await Task.yield()
        #expect(fixture.service.codePrompt == nil && fixture.service.state == .signedOut)
        #expect(fixture.credentials.value == nil && fixture.client.identities == 0)
    }

    @Test func corruptSavedPairDoesNotFallBackOrAuthorizeBundledService() throws {
        let fixture = try AccountTestFixture(buildConfiguration: .available(try bundled))
        defer { fixture.cleanup() }
        fixture.defaults.set(Data("invalid record".utf8), forKey: "lingroveAccountConnectionV1")
        let reopened = AccountSessionService(client: fixture.client, credentials: fixture.credentials, settings: fixture.settings)
        defer { reopened.shutdown() }
        reopened.start()
        reopened.requestCode(email: "synthetic@example.invalid")
        #expect(reopened.configuration == nil && reopened.issue == .invalidConfiguration)
        #expect(fixture.client.sends == 0 && fixture.client.identities == 0)
    }

    @Test func logoutClosesDefaultRestoreEvenWhenCredentialDeletionFails() async throws {
        let fixture = try AccountTestFixture(buildConfiguration: .available(try bundled))
        defer { fixture.cleanup() }
        fixture.service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { fixture.service.state == .awaitingCode }
        fixture.service.submitCode("12345678")
        try await accountEventually { fixture.service.state == .signedIn(fixture.client.currentIdentity) }
        fixture.credentials.failsClear = true
        fixture.service.signOut()
        #expect(try fixture.settings.load()?.allowsSessionRestore == false)
        #expect(fixture.service.issue == .secureStorage)
        let reopened = AccountSessionService(client: fixture.client, credentials: fixture.credentials, settings: fixture.settings)
        defer { reopened.shutdown() }
        reopened.start()
        await Task.yield()
        #expect(reopened.state == .signedOut && reopened.connectionSource == .applicationDefault)
        #expect(fixture.client.identities == 1 && fixture.client.refreshes == 0)
    }

    @Test func resetRetiresOldVerificationAndFailureRetainsCustomScope() async throws {
        let expected = try bundled
        let fixture = try AccountTestFixture(buildConfiguration: .available(expected))
        defer { fixture.cleanup() }
        fixture.configure()
        fixture.service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { fixture.service.state == .awaitingCode }
        fixture.client.holdVerify = true
        fixture.service.submitCode("12345678")
        try await accountEventually { fixture.client.verifyReply != nil }
        fixture.credentials.failsClear = true
        #expect(!fixture.service.useApplicationDefault())
        #expect(fixture.service.configuration == fixture.configuration && fixture.service.connectionSource == .custom)
        #expect(try fixture.settings.load()?.allowsSessionRestore == false)
        fixture.credentials.failsClear = false
        #expect(fixture.service.useApplicationDefault())
        fixture.client.verifyReply?.resume(returning: AccountTestClient.tokens)
        fixture.client.verifyReply = nil
        await Task.yield()
        #expect(fixture.service.configuration == expected && fixture.service.connectionSource == .applicationDefault)
        #expect(fixture.service.state == .signedOut && fixture.credentials.value == nil && fixture.client.identities == 0)
    }

    @Test func removedDefaultStaysDisconnectedUntilExplicitlySelectedAgain() throws {
        let fixture = try AccountTestFixture(buildConfiguration: .available(try bundled))
        defer { fixture.cleanup() }
        #expect(fixture.service.removeConfiguration())
        let reopened = AccountSessionService(client: fixture.client, credentials: fixture.credentials, settings: fixture.settings)
        defer { reopened.shutdown() }
        reopened.start()
        #expect(reopened.configuration == nil && reopened.state == .unconfigured)
        #expect(reopened.canUseApplicationDefault && reopened.useApplicationDefault())
        #expect(reopened.connectionSource == .applicationDefault)
        #expect(try fixture.settings.load()?.allowsSessionRestore == false)
        #expect(fixture.client.sends == 0 && fixture.client.identities == 0)
    }
}
