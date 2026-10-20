import AppKit
import SwiftUI

/// The app environment retains one reusable, activating library window. Floating learning cards
/// keep their existing nonactivating lifetime; only an explicit library command switches focus.
@MainActor
final class VocabularyWindowController: NSWindowController, NSWindowDelegate {
    private let store: VocabularyStore
    private let speech: LearningSpeechController

    init(store: VocabularyStore, speech: LearningSpeechController) {
        self.store = store
        self.speech = speech
        super.init(window: nil)
        store.openEntry = { [weak self] in self?.show(selectedID: $0) }
    }

    required init?(coder: NSCoder) { nil }

    func show(selectedID: UUID? = nil) {
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 940, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = String(localized: "Vocabulary", table: "Vocabulary")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("LingroveVocabulary")
            window.center()
            self.window = window
        }
        // Preserve browsing state on ordinary reopen; an explicit "show this entry" replaces
        // the root with its requested selection, resetting filters that might otherwise hide it.
        if window?.contentView == nil || (selectedID != nil && window?.attachedSheet == nil) {
            window?.contentView = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech, selectedID: selectedID))
        }
        store.loadIfNeeded()
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let target = speech.activeTarget, target.itemID.hasPrefix("vocabulary.") else { return }
        speech.stop(target: target)
    }
}
