import AppKit
import Testing
@testable import Cotabby

/// A registry must bridge a missing parent link without trusting an unrelated overlapping window.
@MainActor
struct LearningPopupWindowRegistryTests {
    @Test func contentAttachmentOwnsOnlyItsVisibleWindowAndReleasesItOnDetach() {
        let registry = LearningPopupWindowRegistry()
        let popup = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 200, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        defer { popup.close() }
        let reader = LearningPopoverReadingView(frame: .zero)
        reader.registry = registry
        popup.contentView?.addSubview(reader)
        popup.orderFrontRegardless()
        let point = CGPoint(x: popup.frame.midX, y: popup.frame.midY)
        #expect(popup.parent == nil && registry.owns(popup))
        #expect(LearningWindowInteraction.contains(point, roots: registry.windows,
                                                   hitWindowNumber: popup.windowNumber))
        #expect(!LearningWindowInteraction.contains(point, roots: registry.windows,
                                                    hitWindowNumber: popup.windowNumber + 100_000))
        popup.ignoresMouseEvents = true
        #expect(!registry.owns(popup))
        popup.ignoresMouseEvents = false
        popup.orderOut(nil)
        #expect(!registry.owns(popup))
        popup.orderFrontRegardless()
        reader.removeFromSuperview()
        #expect(registry.windows.isEmpty && !registry.owns(popup))
    }

    @Test func duplicateReadersAndLateOldHostCallbacksCannotRegisterANewCapture() {
        let original = LearningPopupWindowRegistry(), replacement = LearningPopupWindowRegistry()
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let first = LearningPopoverReadingView(), second = LearningPopoverReadingView()
        first.registry = original
        second.registry = original
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        #expect(original.windows.count == 1)
        first.registry = nil
        #expect(original.windows.count == 1)
        original.reset()
        second.viewDidMoveToWindow()
        #expect(original.windows.count == 1 && replacement.windows.isEmpty)
        second.registry = replacement
        #expect(original.windows.isEmpty && replacement.windows.count == 1)
        second.registry = nil
        #expect(replacement.windows.isEmpty)
    }

    @Test func registrationDoesNotRetainAWindow() {
        let registry = LearningPopupWindowRegistry()
        weak var reference: NSWindow?
        autoreleasepool {
            let window = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            reference = window
            registry.update(window, for: UUID())
        }
        #expect(reference == nil && registry.windows.isEmpty)
    }
}
