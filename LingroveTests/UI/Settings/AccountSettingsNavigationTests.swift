import Foundation
import LingroveCloud
import Testing
@testable import Lingrove

/// These checks exercise the presentation seam without network or storage writes. The window
/// retains URL drafts, while precise search/external links only change paths and arrival anchors.
@Suite(.serialized)
@MainActor
struct AccountSettingsNavigationTests {
    @Test func externalAccountAndSearchRetargetTheSameWindowWithoutDiscardingDrafts() throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        fixture.configure()
        let navigation = SettingsNavigationModel()
        let account = navigation.account
        account.reconcile(configuration: fixture.service.configuration)
        account.api = "https://draft.example.invalid/v1"
        account.auth = "https://draft.example.invalid/auth"
        navigation.reveal(.accountConnection)
        #expect(navigation.selection == .account && account.path == [.service])
        #expect(navigation.highlightedItem == .accountConnection)
        navigation.open(.appearance)
        navigation.openAccount()
        #expect(navigation.selection == .account && account.path.isEmpty)
        #expect(navigation.highlightedItem == nil)
        #expect(account.api == "https://draft.example.invalid/v1")
        #expect(!account.matches(fixture.service.configuration))
        navigation.reveal(.accountSync)
        #expect(account.path == [.sync] && navigation.highlightedItem == .accountSync)
        navigation.reveal(.accountSession)
        #expect(account.path.isEmpty && navigation.highlightedItem == .accountSession)
        #expect(SettingsItem.results(for: "workspace sync").contains(.accountSync))
        #expect(SettingsItem.results(for: "工作区").contains(.accountSync))
        #expect(fixture.client.sends == 0 && fixture.client.identities == 0)
        #expect(fixture.service.configuration == fixture.configuration)
    }

    @Test func changedServiceRefreshesOnlyAPristineOrExplicitlySavedDraft() throws {
        let original = try AccountConfigurationPolicy.configuration(api: "https://first.example.invalid/v1", auth: "https://first.example.invalid/auth")
        let replacement = try AccountConfigurationPolicy.configuration(api: "https://second.example.invalid/v1", auth: "https://second.example.invalid/auth")
        let draft = AccountSettingsNavigation()
        draft.reconcile(configuration: original)
        #expect(draft.matches(original) && !draft.hasChanges(comparedWith: original))
        draft.reconcile(configuration: replacement)
        #expect(draft.matches(replacement))
        draft.api = "https://unsaved.example.invalid/v1"
        draft.reconcile(configuration: original)
        #expect(draft.api == "https://unsaved.example.invalid/v1")
        #expect(!draft.matches(original))
        draft.discardChanges(configuration: original)
        #expect(draft.matches(original))
        draft.api = " HTTPS://SECOND.EXAMPLE.INVALID:443/v1/ "
        draft.auth = "https://second.example.invalid/auth/"
        #expect(draft.matches(replacement))
        draft.reconcile(configuration: replacement)
        #expect(draft.api == replacement.apiBaseURL.absoluteString)
        #expect(draft.auth == replacement.authBaseURL.absoluteString)
        draft.reconcile(configuration: nil)
        #expect(draft.api.isEmpty && draft.auth.isEmpty && !draft.hasChanges(comparedWith: nil))
    }

    @Test func failedConfigurationCannotAuthorizeTheVisibleDraftOrLoseItOnNavigation() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        let navigation = SettingsNavigationModel()
        let draft = navigation.account
        draft.reconcile(configuration: fixture.service.configuration)
        draft.api = "https://new.example.invalid/v1"
        draft.auth = "https://new.example.invalid/auth"
        fixture.credentials.failsClear = true
        #expect(!fixture.service.configure(api: draft.api, auth: draft.auth))
        draft.reconcile(configuration: fixture.service.configuration)
        navigation.open(.general)
        navigation.openAccount()
        #expect(draft.hasChanges(comparedWith: fixture.service.configuration))
        #expect(!draft.matches(fixture.service.configuration))
        #expect(draft.api == "https://new.example.invalid/v1")
        #expect(fixture.service.configuration == fixture.configuration)
        #expect(fixture.client.sends == 1 && fixture.client.verifies == 1)
    }
}
