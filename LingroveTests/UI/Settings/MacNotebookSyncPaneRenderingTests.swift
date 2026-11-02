import AppKit
import Foundation
import LingroveCloud
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// Offscreen native settings hosts contain synthetic values only. Rendering and reopening them
/// does not create a sync owner or stop the process-owned controller; the same real SQLite/HTTP
/// fixture supplies the status shown in each captured state.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct MacNotebookSyncPaneRenderingTests {
    @Test func nativeSettingsPresentWorkspaceOwnershipAndIndependentLaneStates() async throws {
        let f = try MacNotebookSyncFixture(); defer { f.cleanup() }
        try f.saveLocal()
        f.start(); try await f.signIn()
        try await paint(AccountPaneView(account: f.account, syncController: f.sync), name: "workspace")
        try await f.connect()
        try await paint(AccountPaneView(account: f.account, syncController: f.sync), name: "ownership")
        let before = try await f.server.stats().paths.count
        let reopened = AccountPaneView(account: f.account, syncController: f.sync)
        #expect(reopened.syncController === f.sync)
        try await paint(reopened, name: "reopened")
        #expect(try await f.server.stats().paths.count == before)
        #expect(!f.sync.enabled && f.sync.ownershipProposal?.status == "pending")
        f.sync.resolveLocalCorpus(accept: true)
        try await f.server.mode("review-unavailable")
        f.sync.setSynchronizationEnabled(true)
        try await syncEventually { f.sync.corpusStatus == .synchronized && f.sync.reviewStatus == .unavailable }
        try await paint(AccountPaneView(account: f.account, syncController: f.sync), name: "lanes")
        #expect(f.sync.enabled)
    }

    private func paint(_ content: AccountPaneView, name: String) async throws {
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 1_100)
        let window = NSPanel(contentRect: CGRect(x: -3000, y: -3000, width: 800, height: 1_100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_000)
        if let path = ProcessInfo.processInfo.environment["LINGROVE_ACCOUNT_RENDER_OUTPUT"] {
            let destination = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try png.write(to: destination.appendingPathComponent("notebook-sync-\(name).png"))
        }
    }
}
