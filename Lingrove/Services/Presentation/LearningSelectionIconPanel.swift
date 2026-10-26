import AppKit
import SwiftUI

/// A disposable, nonactivating affordance for a captured selection. The reading coordinator
/// supplies the action; merely showing this window never invokes a model or changes host focus.
@MainActor
final class LearningSelectionIconPanel: LearningSelectionAffordancePresenting {
    private var panel: NSPanel?
    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
    func show(anchor: CGRect, action: @escaping () -> Void) {
        show(anchor: anchor, preparing: false, action: action)
    }
    func showProgress(anchor: CGRect) {
        show(anchor: anchor, preparing: true, action: {})
    }
    private func show(anchor: CGRect, preparing: Bool, action: @escaping () -> Void) {
        let window =
            panel
            ?? SelectionIconWindow(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel = window
        window.contentView = NSHostingView(
            rootView: LearningSelectionButton(isPreparing: preparing, action: action))
        window.title = String(localized: "Translate selected text", table: "Learning")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        window.setFrame(
            CGRect(
                x: min(max(anchor.maxX + 5, visible.minX), visible.maxX - 32),
                y: min(max(anchor.minY - 34, visible.minY), visible.maxY - 32), width: 30, height: 30), display: true)
        window.orderFrontRegardless()
    }
}

private final class SelectionIconWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
