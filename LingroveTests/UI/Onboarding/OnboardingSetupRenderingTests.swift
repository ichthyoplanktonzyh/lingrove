import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Opt-in pixel exports at the real wizard width. Fixtures borrow no live app services, and the
/// scene's insert button affects only its example. Keeping both appearances catches native-row
/// contrast problems that a SwiftUI hierarchy assertion cannot detect.
@Suite(.serialized)
@MainActor
struct OnboardingSetupRenderingTests {
    @Test(arguments: [false, true])
    func renderSetupAndExpression(dark: Bool) async throws {
        guard let output = ProcessInfo.processInfo.environment["LINGROVE_SETUP_RENDER_OUTPUT"] else { return }
        let fixture = try RecommendedSetupFixture()
        defer { fixture.cleanup() }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = "\(Bundle.main.preferredLocalizations.first ?? "en")-\(dark ? "dark" : "light")"
        try await paint(RecommendedSetupView(setup: fixture.setup, configureManually: {}), dark: dark,
            size: NSSize(width: 640, height: 610), url: directory.appendingPathComponent("setup-\(suffix).png"))
        try await paint(HomeLearningShowcase(readingSettings: fixture.settings.languageLearning,
            startingScene: .expression, autoplayOnHover: false), dark: dark,
            size: NSSize(width: 600, height: 510), url: directory.appendingPathComponent("expression-player-\(suffix).png"))
        try await paint(ExpressionAssistDemoScene(action: .expressionChoose,
            settings: fixture.settings.languageLearning.expressionAssist, insert: {}), dark: dark,
            size: NSSize(width: 580, height: 330), url: directory.appendingPathComponent("expression-candidate-\(suffix).png"))
        #expect(fixture.transfers.isEmpty)
        #expect(!fixture.settings.languageLearning.expressionAssist.enabled)
    }

    private func paint<V: View>(_ view: V, dark: Bool, size: NSSize, url: URL) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -3000, y: -3000), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        #expect(png.count > 1_000)
    }
}
