import AppKit
import Foundation
import Testing
@testable import Lingrove

/// Measures production containers over the transition, including asynchronous page loads.
/// Only synthetic windows/preferences participate; changing pages must not resize their chrome.
@Suite(.serialized) @MainActor
struct NotebookNavigationGeometryTests {
    @Test func workspaceAndAccountKeepTheirContentViewport() async throws {
        let fixture = try NotebookWorkspaceFixture(usesRealProgress: true)
        do {
            _ = try await fixture.seed()
            fixture.window.show()
            let window = try workspaceRequire(fixture.window.window)
            window.setFrameOrigin(.init(x: -3000, y: -3000))
            try await Task.sleep(for: .milliseconds(300))
            var records: [[String: Any]] = []
            records.append(record(window, route: "baseline-corpus", tick: 0))
            let baseline = window.contentLayoutRect
            let baselineFrame = window.frame
            for destination in [NotebookWorkspaceDestination.review, .progress, .corpus, .review, .progress] {
                fixture.window.navigate(to: destination)
                for tick in 0..<12 {
                    window.contentView?.layoutSubtreeIfNeeded()
                    records.append(record(window, route: destination.rawValue, tick: tick))
                    #expect(window.contentLayoutRect == baseline)
                    #expect(window.frame == baselineFrame)
                    try await Task.sleep(for: .milliseconds(25))
                }
            }
            fixture.window.onShowAccount?()
            let settings = try workspaceRequire(fixture.settingsWindow), navigation = try workspaceRequire(fixture.settings).navigation.account
            settings.setFrameOrigin(.init(x: -3000, y: -3000))
            try await Task.sleep(for: .milliseconds(300))
            records.append(record(settings, route: "baseline-account", tick: 0))
            let accountBaseline = settings.contentLayoutRect
            let accountFrame = settings.frame
            for page in [AccountSettingsPage.service, .sync, .service] {
                navigation.show(page)
                for tick in 0..<12 {
                    settings.contentView?.layoutSubtreeIfNeeded()
                    records.append(record(settings, route: "account-\(page)", tick: tick))
                    #expect(settings.contentLayoutRect == accountBaseline)
                    #expect(settings.frame == accountFrame)
                    try await Task.sleep(for: .milliseconds(25))
                }
                navigation.showOverview()
                try await Task.sleep(for: .milliseconds(200))
            }
            if let directory = ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_EVIDENCE_DIR"] {
                try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("navigation-geometry.json"))
            }
            await fixture.cleanUp()
        } catch { await fixture.cleanUp(); throw error }
    }
    private func record(_ window: NSWindow, route: String, tick: Int) -> [String: Any] {
        ["route": route, "tick": tick, "frame": NSStringFromRect(window.frame),
         "layout": NSStringFromRect(window.contentLayoutRect), "content": NSStringFromRect(window.contentView?.frame ?? .zero),
         "toolbar": window.toolbar?.identifier ?? "none", "style": window.toolbarStyle.rawValue, "mask": window.styleMask.rawValue,
         "displayMode": window.toolbar?.displayMode.rawValue ?? -1]
    }
}
