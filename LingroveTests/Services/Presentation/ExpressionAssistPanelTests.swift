import AppKit
import Testing
@testable import Lingrove

/// Exercises the actual text input client and two AppKit windows, without an external editor or
/// Accessibility permission. Events are delivered only to this test-owned text view.
@Suite(.serialized)
@MainActor
struct ExpressionAssistPanelTests {
    @Test
    func quietInputKeepsNativeCompositionAndConfirmsOnlyAReadyChoice() async throws {
        let panel = ExpressionAssistPanelController()
        defer { panel.hide(restoringHost: false) }
        var accepted: [String] = []
        var submitted = 0
        var compositionStates: [Bool] = []
        panel.onAccept = { accepted.append($0.text) }
        panel.onSubmit = { submitted += 1 }
        panel.onQueryChanged = { _, composing in compositionStates.append(composing) }
        await panel.show(context: try context(), trigger: "??", initialQuery: "")
        let window = try inputWindow()
        let input = try #require(window.firstResponder as? NSTextView)
        #expect(panel.isVisible && panel.hasKeyFocus && window.isKeyWindow)
        #expect(!window.hasShadow && !input.drawsBackground)
        #expect(!window.styleMask.contains(.nonactivatingPanel))
        #expect(NSApp.isActive, "The input owner must be active before real keyboard/IME delivery is possible")
        input.keyDown(with: try key(36, characters: "\r", window: window))
        #expect(submitted == 1 && accepted.isEmpty)
        input.setMarkedText("pai", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(input.hasMarkedText())
        #expect(compositionStates.last == true, "Preedit must cancel pending generation before committed text changes")
        panel.update(result: .init(candidates: [.init(text: "rule out", hint: "排除")]), message: nil, loading: false)
        input.keyDown(with: try key(36, characters: "\r", window: window))
        #expect(accepted.isEmpty, "Return belongs to the input method while composition is active")
        input.unmarkText()
        panel.update(result: .init(candidates: [.init(text: "rule out", hint: "排除"),
            .init(text: "exclude", hint: "排除在外")]), message: nil, loading: false)
        input.keyDown(with: try key(125, characters: "", window: window))
        input.keyDown(with: try key(48, characters: "\t", window: window))
        #expect(accepted == ["exclude"])
        #expect(submitted == 1)
        await Task.yield()
    }

    @Test
    func middleTextUsesExpandedInputAndLongDescriptionsStayWithinTheScreen() async throws {
        let panel = ExpressionAssistPanelController()
        defer { panel.hide(restoringHost: false) }
        await panel.show(context: try context(trailing: " yet."), trigger: "??", initialQuery: String(repeating: "描述\n", count: 100))
        let window = try inputWindow()
        let input = try #require(window.firstResponder as? NSTextView)
        let screen = try #require(window.screen)
        #expect(window.hasShadow)
        #expect(window.frame.height <= max(50, min(180, screen.visibleFrame.height / 3)) + 16)
        #expect(input.enclosingScrollView != nil && input.bounds.height > window.frame.height)
        #expect(screen.visibleFrame.contains(window.frame))
    }

    @Test
    func nativeEditNotificationsCoalesceLayoutAndReuseUnchangedCandidates() async throws {
        let panel = ExpressionAssistPanelController()
        defer { panel.hide(restoringHost: false) }
        panel.onQueryChanged = { [weak panel] _, _ in panel?.update(result: nil, message: nil, loading: false) }
        await panel.show(context: try context(), trigger: "??", initialQuery: "")
        let input = try #require(try inputWindow().firstResponder as? NSTextView)
        let initialLayouts = panel.inputLayoutPasses
        let initialCandidates = panel.candidateBuilds
        for length in 1...20 {
            input.setMarkedText(String(repeating: "p", count: length % 8 + 1),
                selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            // Some input methods also send a delegate notification for the same preedit update.
            panel.textDidChange(Notification(name: NSText.didChangeNotification, object: input))
        }
        #expect(panel.inputLayoutPasses == initialLayouts, "Editing must not force synchronous layout from inside TextKit")
        for _ in 0..<100 where panel.inputLayoutPasses == initialLayouts {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(panel.inputLayoutPasses == initialLayouts + 1)
        #expect(panel.candidateBuilds == initialCandidates, "Preedit hides once without rebuilding candidate views")
        input.unmarkText()
        let afterCommit = panel.candidateBuilds
        #expect(afterCommit == initialCandidates, "IME confirmation restores visibility without rebuilding unchanged content")
        for _ in 0..<20 {
            panel.textDidChange(Notification(name: NSText.didChangeNotification, object: input))
            panel.update(result: nil, message: nil, loading: false)
        }
        #expect(panel.inputLayoutPasses == initialLayouts + 1)
        #expect(panel.candidateBuilds == afterCommit)
    }

    private func context(trailing: String = "") throws -> FocusedInputSnapshot {
        let screen = try #require(NSScreen.main).visibleFrame
        return LingroveTestFixtures.focusedInputSnapshot(
            caretRect: CGRect(x: screen.midX - 200, y: screen.midY, width: 1, height: 18),
            inputFrameRect: CGRect(x: screen.minX + 20, y: screen.midY - 50, width: screen.width - 40, height: 150),
            precedingText: "We still can't ??", trailingText: trailing)
    }

    private func inputWindow() throws -> NSWindow {
        try #require(NSApp.windows.first {
            $0.isVisible && $0.title == String(localized: "Expression assistance", table: "Learning")
        })
    }

    private func key(_ code: UInt16, characters: String, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
    }
}
