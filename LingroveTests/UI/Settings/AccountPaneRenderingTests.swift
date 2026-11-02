import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Renders actual native account forms with synthetic state. It closes/reopens the host around
/// the same app-owned service, proving a window lifetime does not re-request OTP or create a
/// refresh owner. Optional PNGs contain only fixture input and never capture the user's screen.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct AccountPaneRenderingTests {
    @Test
    func reopenedNativeFormsObserveTheSameSessionAndRenderAccountStates() async throws {
        let fixture = try AccountTestFixture()
        defer { fixture.cleanup() }
        try await paint(AccountPaneView(account: fixture.service), name: "unconfigured")
        fixture.configure()
        fixture.service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { fixture.service.state == .awaitingCode }
        let first = AccountPaneView(account: fixture.service)
        try await paint(first, name: "email-code")
        let reopened = AccountPaneView(account: fixture.service)
        #expect(first.account === reopened.account)
        try await paint(reopened, name: "email-code-reopened")
        #expect(fixture.client.sends == 1 && fixture.client.refreshes == 0)
        fixture.service.submitCode("12345678")
        try await accountEventually { if case .signedIn = fixture.service.state { return true }; return false }
        try await paint(AccountPaneView(account: fixture.service), name: "signed-in")
        fixture.client.failure = .network
        _ = try? await fixture.service.confirmedIdentity(recheck: true)
        try await paint(AccountPaneView(account: fixture.service), name: "offline")
        fixture.service.signOut()
        #expect(fixture.service.state == .signedOut)
        #expect(SettingsItem.accountSession.category == .account)
        #expect(SettingsItem.results(for: "email login").contains(.accountSession))
    }

    private func paint(_ content: AccountPaneView, name: String) async throws {
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 900)
        let window = NSPanel(contentRect: CGRect(x: -3000, y: -3000, width: 800, height: 900),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_000)
        if let directory = ProcessInfo.processInfo.environment["LINGROVE_ACCOUNT_RENDER_OUTPUT"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try png.write(to: destination.appendingPathComponent("account-\(name).png"))
        }
    }
}
