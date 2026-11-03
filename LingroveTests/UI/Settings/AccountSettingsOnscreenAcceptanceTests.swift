import AppKit
import Foundation
import Testing
@testable import Lingrove

/// A bounded, explicitly enabled handoff exposes the real Settings coordinator with synthetic
/// in-memory authentication. It never starts sync, models, input monitors or the installed app.
/// The operator checks drafts, email/code, back navigation and another Settings pane; durable
/// ownership/sync decisions are independently covered by focused module integration tests.
@Suite(.serialized, .timeLimit(.minutes(8)))
@MainActor
struct AccountSettingsOnscreenAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINGROVE_ACCOUNT_ONSCREEN"] != nil))
    func visibleNativeAccountNavigationAndSignIn() async throws {
        let output = URL(fileURLWithPath: try workspaceRequire(ProcessInfo.processInfo.environment["LINGROVE_ACCOUNT_ONSCREEN"]))
        let account = try AccountTestFixture()
        account.configure()
        let fixture = try NotebookWorkspaceFixture(accountService: account.service)
        do {
            fixture.window.prepareWindow()
            fixture.window.onShowAccount?()
            let coordinator = try workspaceRequire(fixture.settings)
            let window = try workspaceRequire(fixture.settingsWindow)
            window.center()
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                "windowTitle": window.title, "syntheticEmail": "synthetic@example.invalid", "syntheticCode": "12345678",
                "bundleID": Bundle.main.bundleIdentifier ?? "", "preferences": fixture.suite,
                "database": fixture.repository.databaseURL.path,
                "done": output.appendingPathComponent("done.json").path], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("ready.json"))
            let done = output.appendingPathComponent("done.json")
            let deadline = ContinuousClock.now.advanced(by: .seconds(360))
            while !FileManager.default.fileExists(atPath: done.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try workspaceRequire(FileManager.default.fileExists(atPath: done.path), "The native account handoff did not finish")
            workspaceExpect(account.client.sends == 1 && account.client.verifies == 1)
            workspaceExpect(account.service.state == .signedIn(account.client.currentIdentity))
            workspaceExpect(coordinator.navigation.selection == .appearance)
            workspaceExpect(coordinator.navigation.account.matches(account.service.configuration))
            workspaceExpect(!fixture.sync.enabled)
            try JSONSerialization.data(withJSONObject: ["sends": account.client.sends, "verifies": account.client.verifies,
                "signedIn": account.service.state == .signedIn(account.client.currentIdentity),
                "finalSettingsPane": coordinator.navigation.selection.rawValue, "syncEnabled": fixture.sync.enabled,
                "appearanceOverride": window.appearance?.name.rawValue ?? "inherited",
                "systemAppearanceChanged": false, "userDataTouched": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("native-result.json"))
            await fixture.cleanUp()
            account.cleanup()
        } catch {
            await fixture.cleanUp()
            account.cleanup()
            throw error
        }
    }
}
