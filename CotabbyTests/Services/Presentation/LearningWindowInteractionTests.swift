import AppKit
import Testing
@testable import Cotabby

/// Real AppKit window families with injected Window Server hits keep this regression independent
/// of the frontmost application, system input, Accessibility, and native dictionary availability.
@Suite(.serialized)
@MainActor
struct LearningWindowInteractionTests {
    @Test
    func appKitIdentityResolvesToThisProcessInWindowServer() async throws {
        let screen = try #require(NSScreen.main?.visibleFrame)
        let window = makePanel(CGRect(x: screen.minX + 40, y: screen.minY + 40, width: 180, height: 80))
        defer { window.close() }
        // Check the actual global ID namespace without assuming a background test fixture is
        // the frontmost hit. Other suites and applications may legitimately cover its pixels.
        // Exact hit routing is tested below; native cross-app clicks still require acceptance.
        // Window-device allocation is synchronous, but Window Server registration is not.
        // Yield until the public server listing sees this device; do not require foreground focus.
        var owner: Int?
        for _ in 0..<20 {
            let descriptions = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber))
                as? [[String: Any]] ?? []
            let description = descriptions.first { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
            owner = description?[kCGWindowOwnerPID as String] as? Int
            if owner != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(owner == Int(ProcessInfo.processInfo.processIdentifier),
                "The AppKit identity must resolve to this process in Window Server, without cross-app aliasing")
    }

    @Test
    func onlyTheFrontmostVisibleOwnedWindowCountsAsInternal() {
        let root = makePanel(CGRect(x: 100, y: 100, width: 240, height: 140))
        let lookup = makePanel(CGRect(x: 120, y: 120, width: 220, height: 120))
        let menu = makePanel(CGRect(x: 400, y: 120, width: 180, height: 80))
        let foreign = makePanel(lookup.frame)
        defer { menu.close(); lookup.close(); root.close(); foreign.close() }
        root.ignoresMouseEvents = true
        root.addChildWindow(lookup, ordered: .above)
        lookup.addChildWindow(menu, ordered: .above)
        let point = CGPoint(x: 160, y: 160)
        #expect(LearningWindowInteraction.contains(point, roots: [root], hitWindowNumber: lookup.windowNumber))
        #expect(!LearningWindowInteraction.contains(point, roots: [root], hitWindowNumber: foreign.windowNumber),
                "An overlapping foreign window must not be mistaken for our underlying dictionary")
        #expect(!LearningWindowInteraction.contains(point, roots: [root], hitWindowNumber: root.windowNumber))
        #expect(LearningWindowInteraction.contains(CGPoint(x: 440, y: 150), roots: [root], hitWindowNumber: menu.windowNumber),
                "Nested action popovers may extend beyond the native dictionary's frame")
        lookup.orderOut(nil)
        #expect(!LearningWindowInteraction.contains(point, roots: [root], hitWindowNumber: lookup.windowNumber))
    }

    @Test
    func unknownOrInvalidHitsAreExternal() {
        let root = makePanel(CGRect(x: 100, y: 100, width: 240, height: 140))
        defer { root.close() }
        let point = CGPoint(x: 160, y: 160)
        for number in [-1, 0] {
            #expect(!LearningWindowInteraction.contains(point, roots: [root], hitWindowNumber: number))
        }
        #expect(!LearningWindowInteraction.contains(CGPoint(x: CGFloat.nan, y: 160), roots: [root],
                                                   hitWindowNumber: root.windowNumber))
        #expect(!LearningWindowInteraction.contains(CGPoint(x: 900, y: 900), roots: [root],
                                                   hitWindowNumber: root.windowNumber))
    }

    private func makePanel(_ frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.orderFrontRegardless()
        panel.display()
        return panel
    }
}
