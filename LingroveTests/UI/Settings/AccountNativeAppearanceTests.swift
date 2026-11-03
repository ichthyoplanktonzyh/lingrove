import AppKit
import LingroveCloud
import SwiftUI
import Testing
@testable import Lingrove

/// Private native windows are the appearance authority. These tests change only their own
/// NSAppearance, never NSApp, macOS preferences or a SwiftUI colorScheme environment. Recording
/// the resolved environment catches the old forced-dark preference on account pages and sheets.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct AccountNativeAppearanceTests {
    @Test func consumedCodeRouteKeepsPendingIdentityConfirmationAlive() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        fixture.configure()
        fixture.service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { fixture.service.state == .awaitingCode }
        let host = AccountNativeAppearanceHost(
            LingroveAccountSignInSheet(account: fixture.service, connectionIsSaved: true),
            appearance: .aqua, width: 560, height: 500)
        defer { host.close() }
        try await host.checkAndCapture("account-before-verification")
        fixture.client.holdIdentity = true
        fixture.service.submitCode("12345678")
        try await accountEventually { fixture.client.identityReply != nil }
        try await host.checkAndCapture("account-identity-pending")
        #expect(fixture.service.codePrompt == nil && fixture.service.state == .working(.verifyingCode))
        fixture.client.identityReply?.resume(returning: fixture.client.currentIdentity)
        fixture.client.identityReply = nil
        try await accountEventually { fixture.service.state == .signedIn(fixture.client.currentIdentity) }
        #expect(fixture.credentials.value?.identity == fixture.client.currentIdentity)
    }

    @Test func unavailableLoginKeepsNativeAppearanceAndDoesNotRequestAService() async throws {
        for build in [AccountBuildConfiguration.missing, .invalid] {
            let fixture = try AccountTestFixture(buildConfiguration: build)
            defer { fixture.cleanup() }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let signIn = AccountNativeAppearanceHost(
                    LingroveAccountSignInSheet(account: fixture.service, connectionIsSaved: false, onOpenService: {}),
                    appearance: appearance, width: 560, height: 500)
                try await signIn.checkAndCapture(build == .missing ? "account-unconfigured" : "account-invalid-default")
                signIn.close()
            }
            #expect(fixture.service.configuration == nil && fixture.client.sends == 0 && fixture.client.identities == 0)
        }
    }

    @Test func accountPagesAndAuthenticationSheetsInheritTheirNativeWindow() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        fixture.configure()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let route = AccountSettingsNavigation()
            let pane = AccountNativeAppearanceHost(AccountPaneView(account: fixture.service, navigation: route), appearance: appearance)
            try await pane.checkAndCapture("account-overview")
            route.show(.service)
            try await pane.checkAndCapture("account-service")
            route.showOverview()
            try await pane.checkAndCapture("account-return")
            pane.close()
            let signIn = AccountNativeAppearanceHost(
                LingroveAccountSignInSheet(account: fixture.service, connectionIsSaved: true), appearance: appearance, width: 560, height: 500)
            try await signIn.checkAndCapture("account-email")
            signIn.close()
            fixture.service.requestCode(email: "synthetic@example.invalid")
            try await accountEventually { fixture.service.state == .awaitingCode }
            let code = AccountNativeAppearanceHost(
                LingroveAccountSignInSheet(account: fixture.service, connectionIsSaved: true), appearance: appearance, width: 560, height: 500)
            try await code.checkAndCapture("account-code")
            code.close()
            fixture.service.cancelSignIn()
        }
        #expect(fixture.client.sends == 2 && fixture.client.verifies == 0 && fixture.client.identities == 0)
    }

    @Test func workspaceOwnershipAndChooserInheritTheirNativeWindowWithoutOptingIn() async throws {
        let fixture = try MacNotebookSyncFixture()
        defer { fixture.cleanup() }
        try fixture.saveLocal()
        fixture.start()
        try await fixture.signIn()
        try await fixture.connect()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let route = AccountSettingsNavigation()
            route.show(.sync)
            let pane = AccountNativeAppearanceHost(
                AccountPaneView(account: fixture.account, syncController: fixture.sync, navigation: route), appearance: appearance)
            try await pane.checkAndCapture("account-sync-ownership")
            pane.close()
            let chooser = AccountNativeAppearanceHost(LingroveAccountWorkspaceSelectionSheet(controller: fixture.sync),
                appearance: appearance, width: 560, height: 480)
            try await chooser.checkAndCapture("account-workspace-chooser")
            chooser.close()
        }
        #expect(!fixture.sync.enabled && fixture.sync.ownershipProposal?.status == "pending")
    }

    @Test func settingsCoordinatorReusesOneWindowAndExternalAccountReturnsToOverview() async throws {
        let fixture = try NotebookWorkspaceFixture()
        do {
            fixture.window.prepareWindow()
            fixture.window.onShowAccount?()
            let coordinator = try workspaceRequire(fixture.settings)
            let window = try workspaceRequire(fixture.settingsWindow)
            window.setFrameOrigin(.init(x: -3000, y: -3000))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                coordinator.navigation.account.show(.service)
                try await settle(window)
                coordinator.showAccount()
                try await settle(window)
                workspaceExpect(coordinator.navigation.account.path.isEmpty)
                workspaceExpect(window.appearance?.name == appearance)
                workspaceExpect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
                coordinator.navigation.open(.appearance)
                try await settle(window)
                workspaceExpect(window.appearance?.name == appearance)
                coordinator.showAccount()
                try await settle(window)
                workspaceExpect(fixture.settingsWindow === window)
                workspaceExpect(coordinator.navigation.selection == .account && coordinator.navigation.account.path.isEmpty)
                workspaceExpect(window.appearance?.name == appearance)
                try await captureWorkspace(window, name: "settings-account-" + appearance.rawValue)
            }
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

/// One test owns one host plus a plain observation sink. Its background reads the resolved
/// SwiftUI environment after native inheritance; it never supplies a preferred color scheme.
@MainActor
private final class AccountNativeAppearanceHost {
    let view: NSHostingView<AnyView>
    let window: NSWindow
    let appearance: NSAppearance.Name
    private let observation = AccountAppearanceObservation()

    init<Content: View>(_ content: Content, appearance: NSAppearance.Name, width: CGFloat = 760, height: CGFloat = 720) {
        self.appearance = appearance
        let observation = observation
        view = NSHostingView(rootView: AnyView(content.background(AccountAppearanceReader(observation: observation))))
        window = NSWindow(contentRect: .init(x: -3000, y: -3000, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.orderFrontRegardless()
    }

    func close() { window.contentView = nil; window.close() }

    func checkAndCapture(_ name: String) async throws {
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
        let resolved = observation.colorScheme
        let windowAppearance = window.appearance?.name
        let expected: ColorScheme = appearance == .darkAqua ? .dark : .light
        #expect(resolved == expected)
        #expect(windowAppearance == appearance)
        guard let output = ProcessInfo.processInfo.environment["LINGROVE_ACCOUNT_RENDER_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = name + "-" + appearance.rawValue
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_000)
        try png.write(to: directory.appendingPathComponent(basename + ".png"))
        try JSONSerialization.data(withJSONObject: ["windowAppearance": windowAppearance?.rawValue ?? "nil",
            "resolvedColorScheme": resolved == .dark ? "dark" : "light", "title": window.title,
            "viewColorSchemeForced": false, "systemAppearanceChanged": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(basename + ".json"))
    }
}

@MainActor
private final class AccountAppearanceObservation {
    var colorScheme: ColorScheme?
}

private struct AccountAppearanceReader: View {
    let observation: AccountAppearanceObservation
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Color.clear.onChange(of: colorScheme, initial: true) { _, value in observation.colorScheme = value }
    }
}
