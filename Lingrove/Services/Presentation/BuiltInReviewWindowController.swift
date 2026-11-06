import AppKit
import SwiftUI

/// The app's review facade owns one reusable activating window. Its delegate cancels only the
/// review UI session. The local key monitor is installed only while this window is open and
/// checks the exact key window, sheet and text responder before consuming an event.
@MainActor
final class BuiltInReviewWindowController: NSWindowController, NSWindowDelegate {
    let session: BuiltInReviewSession
    private var keyMonitor: Any?
    private weak var presentationWindow: NSWindow?
    private var isEmbeddedPresentationActive = false

    init(session: BuiltInReviewSession) {
        self.session = session
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { nil }

    func show(selection: VocabularySelection?) {
        guard presentationWindow == nil else { return }
        prepareWindow()
        session.open(selection: selection)
        installKeyMonitor()
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Preparing the host separately also lets native component tests render an isolated
    /// window without launching the user's running Lingrove or activating another app.
    func prepareWindow() {
        guard window == nil, presentationWindow == nil else { return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1020, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = BuiltInReviewCopy.text("title")
        window.identifier = .init("LingroveBuiltInReview")
        window.minSize = CGSize(width: 760, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: BuiltInReviewWindowView(session: session))
        // Standalone and embedded review both inherit their owning native window. Applying a
        // local dark appearance here would disagree with Settings/corpus and with system changes.
        window.contentView?.appearance = nil
        window.setFrameAutosaveName("LingroveBuiltInReview")
        window.center()
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        session.close()
    }

    func shutdown() {
        removeKeyMonitor()
        session.close()
        close()
    }

    /// Embedding borrows a window without taking its delegate or content view. The facade owns
    /// exactly one monitor, whether its client uses the old standalone host or the workspace.
    func attachPresentation(to window: NSWindow) {
        removeKeyMonitor()
        if self.window != nil { close() }
        presentationWindow = window
        isEmbeddedPresentationActive = false
    }

    func setPresentationActive(_ active: Bool) {
        isEmbeddedPresentationActive = active
        if active, presentationWindow != nil { installKeyMonitor() } else { removeKeyMonitor() }
    }

    /// AppKit's field editor is an NSTextView, including when a SwiftUI TextField owns focus.
    /// Noneditable selectable Card text must not be mistaken for an editing session.
    func keyboardAction(for event: NSEvent, isKeyWindow: Bool) -> BuiltInReviewKeyboardPolicy.Action? {
        guard let window = presentationWindow ?? window, event.window === window,
              presentationWindow == nil || isEmbeddedPresentationActive else { return nil }
        let editing: Bool
        if let text = window.firstResponder as? NSTextView {
            editing = text.isEditable
        } else if let field = window.firstResponder as? NSTextField {
            editing = field.isEditable
        } else { editing = false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let key: BuiltInReviewKeyboardPolicy.Key
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "z" {
            key = .undo
        } else if modifiers.isEmpty, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") {
            key = .reveal
        } else if modifiers.isEmpty, let characters = event.charactersIgnoringModifiers, characters.count == 1,
                  let number = Int(characters), (1...4).contains(number) {
            key = .digit(number)
        } else { key = .other }
        let phase: BuiltInReviewKeyboardPolicy.Phase
        switch session.practice?.phase {
        case .question: phase = .question
        case .answer: phase = .answer
        case .finished: phase = .finished
        case nil: phase = .other
        }
        return BuiltInReviewKeyboardPolicy.action(key: key, phase: phase, interaction: .init(
            isKeyWindow: isKeyWindow && session.route == .practice, isEditingText: editing,
            hasSheet: window.attachedSheet != nil || session.draft != nil || session.batchDraft != nil
                || session.noteTypeDraft != nil || session.noteDraft != nil,
            isBusy: session.isBusy, canUndo: session.latestUndo != nil))
    }

    func handle(_ action: BuiltInReviewKeyboardPolicy.Action) {
        switch action {
        case .reveal: session.reveal()
        case let .rate(rating): session.rate(rating)
        case .undo: if let undo = session.latestUndo { session.undo(undo) }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // AppKit invokes a local monitor synchronously during main-thread event dispatch.
            // Assert that contract instead of hopping actors and handling the key too late.
            let consumed = MainActor.assumeIsolated {
                guard let self, let action = self.keyboardAction(for: event,
                    isKeyWindow: NSApplication.shared.keyWindow === (self.presentationWindow ?? self.window)) else { return false }
                self.handle(action)
                return true
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
