import AppKit
import Logging
import SwiftUI

/// Each learning panel owns this narrow AppKit boundary for its lifetime. A clicked button
/// supplies text and geometry; AppKit supplies the dictionary's original UI. Each lookup owns
/// a separate transparent source window because showDefinition has no async cancellation token.
@MainActor
final class LearningSystemDictionaryPresenter {
    private var sourceWindow: LearningDictionarySourcePanel?
    private weak var lookupWindow: NSWindow?
    private var lookupID = UUID().uuidString
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let display: @MainActor (NSView, NSAttributedString, NSPoint) -> Void
    static let favoriteViewIdentifier = NSUserInterfaceItemIdentifier("LingroveVocabularyFavorite")
    private var favoriteView: NSView?
    private var savedVocabularyCapture: VocabularyCapture?
    var interactionWindows: [NSWindow?] { [sourceWindow, lookupWindow] }
    var vocabularyCapture: VocabularyCapture? {
        guard sourceWindow?.childWindows?.contains(where: { $0.isVisible && $0.frame.width > 160 && $0.frame.height > 60 }) == true
        else { return nil }
        return savedVocabularyCapture
    }

    /// Tests replace only the OS display call, preserving real anchor geometry and window lifetime.
    init(display: @escaping @MainActor (NSView, NSAttributedString, NSPoint) -> Void = displayDefinition) {
        self.display = display
    }

    func show(_ word: String, from button: NSButton, vocabulary: VocabularyStore? = nil, capture: VocabularyCapture? = nil) {
        guard button.title == word else { return }
        let title = button.cell?.titleRect(forBounds: button.bounds) ?? button.bounds
        show(word, from: button, textBounds: title, font: button.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize),
            vocabulary: vocabulary, capture: capture)
    }

    /// Inline sentence lookup and existing word buttons share the same native popup lifetime.
    /// Callers validate document/text identity; this boundary validates the live view and geometry.
    func show(_ word: String, from sourceView: NSView, textBounds: CGRect, font: NSFont,
              vocabulary: VocabularyStore? = nil, capture: VocabularyCapture? = nil) {
        guard !word.isEmpty, word.utf8.count <= 256,
              let parent = sourceView.window, parent.isVisible, !sourceView.isHiddenOrHasHiddenAncestor,
              !sourceView.visibleRect.isEmpty, textBounds.origin.x.isFinite, textBounds.origin.y.isFinite,
              textBounds.width.isFinite, textBounds.height.isFinite,
              textBounds.width > 0, textBounds.height > 0,
              sourceView.visibleRect.intersects(textBounds) else { return }
        let frame = parent.convertToScreen(sourceView.convert(textBounds, to: nil))
        guard frame.width > 0, frame.height > 0 else { return }
        dismiss(reason: "lookup-replaced")
        lookupID = UUID().uuidString
        let source = LearningDictionarySourcePanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        source.isReleasedWhenClosed = false
        source.isOpaque = false
        source.backgroundColor = .clear
        source.hasShadow = false
        source.ignoresMouseEvents = true
        source.level = parent.level
        source.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        source.hidesOnDeactivate = false
        let view = NSView(frame: CGRect(origin: .zero, size: source.contentLayoutRect.size))
        source.contentView = view
        source.allowsDictionaryWindows = true
        sourceWindow = source
        savedVocabularyCapture = capture
        if let vocabulary, let capture {
            source.onDictionaryWindow = { [weak self, weak source] child in
                // AppKit owns the lookup content. The public child-window hook gives us its
                // top-level content view; no private view classes or dictionary text are read.
                Task { @MainActor [weak self, weak source, weak child] in
                    guard let self, let source, let child, self.sourceWindow === source,
                          source.allowsDictionaryWindows, child.frame.width > 160, child.frame.height > 60 else { return }
                    self.observeLookup(child)
                    self.showFavorite(vocabulary, capture: capture, in: child)
                }
            }
        }
        // The empty transparent view paints nothing over the real button. Its child relationship
        // makes native lookup move with the correspondence detail and stay inside its click-monitor family.
        parent.addChildWindow(source, ordered: .above)
        source.orderFrontRegardless()
        let text = NSAttributedString(string: word, attributes: [.font: font])
        // The proxy is unflipped. The baseline is view-local, not a screen point or a window origin.
        // NSWindow aligns its frame to backing pixels. Carry the title's fractional offset into
        // the view-local baseline so that rounding the transparent window does not move the word.
        let localTitle = source.convertFromScreen(frame)
        let baseline = NSPoint(x: localTitle.minX, y: localTitle.midY - (font.ascender + font.descender) / 2)
        display(view, text, baseline)
        recordInteraction(kind: "lookup-dispatched", window: nil)
    }

    func owns(_ window: NSWindow?) -> Bool {
        guard let sourceWindow else { return false }
        var ancestor = window
        while let current = ancestor {
            if current === sourceWindow { return true }
            ancestor = current.parent
        }
        return false
    }

    @discardableResult
    func dismiss(reason: String = "explicit") -> Bool {
        guard let source = sourceWindow else { return false }
        recordInteraction(kind: "dismiss-requested." + reason, window: nil)
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        lookupWindow = nil
        sourceWindow = nil
        savedVocabularyCapture = nil
        favoriteView?.removeFromSuperview()
        favoriteView = nil
        source.allowsDictionaryWindows = false
        // The transparent source can outlive a popover dismissed by AppKit itself. Only visible
        // native children justify consuming an extra Escape before closing the correspondence detail.
        let wasVisible = (source.childWindows ?? []).contains { $0.isVisible }
        // Hide the source before closing its descendants. Closing only the synchronous highlight
        // does not cancel a pending popover; AppKit can otherwise show it after the user resumed.
        source.orderOut(nil)
        closeDescendants(of: source)
        source.close()
        return wasVisible
    }

    /// Window IDs and booleans distinguish our dismissal from a native close without recording
    /// the looked-up word, host text, or window title. The panel forwards its existing monitors.
    func recordInteraction(kind: String, window: NSWindow?, hitWindowNumber: Int = -1) {
        guard sourceWindow != nil else { return }
        CotabbyLogger.learning.debug("Native dictionary lifecycle", metadata: [
            "stage": .string(kind), "lookup_id": .string(lookupID),
            "source_window": .stringConvertible(sourceWindow?.windowNumber ?? -1),
            "lookup_window": .stringConvertible(lookupWindow?.windowNumber ?? -1),
            "event_window": .stringConvertible(window?.windowNumber ?? -1),
            "hit_window": .stringConvertible(hitWindowNumber),
            "lookup_visible": .stringConvertible(lookupWindow?.isVisible == true),
            "lookup_attached": .stringConvertible(lookupWindow?.parent === sourceWindow),
            "event_owned": .stringConvertible(owns(window)),
            "pointer_in_lookup": .stringConvertible(lookupWindow?.frame.contains(NSEvent.mouseLocation) == true),
            "app_active": .stringConvertible(NSApp.isActive)
        ])
    }

    private func observeLookup(_ window: NSWindow) {
        guard lookupWindow !== window else { return }
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        lookupWindow = window
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.recordInteraction(kind: "notification." + note.name.rawValue, window: nil) }
            }
            lifecycleObservers.append(observer)
        }
        recordInteraction(kind: "lookup-attached", window: nil)
    }

    private func showFavorite(_ store: VocabularyStore, capture: VocabularyCapture, in dictionary: NSWindow) {
        guard let content = dictionary.contentView else { return }
        favoriteView?.removeFromSuperview()
        // Keep the accessory in the lookup window so its clicks share the native content's
        // window identity instead of introducing a second transient ownership boundary.
        // Only this top-level public view is extended; AppKit retains its content and layout.
        let accessory = NSHostingView(rootView: VocabularyFavoriteButton(store: store, capture: capture)
            .padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)))
        accessory.identifier = Self.favoriteViewIdentifier
        accessory.frame = CGRect(x: content.bounds.maxX - 42,
            y: content.isFlipped ? content.bounds.minY + 8 : content.bounds.maxY - 42, width: 34, height: 34)
        accessory.autoresizingMask = content.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        content.addSubview(accessory, positioned: .above, relativeTo: nil)
        favoriteView = accessory
    }

    private func closeDescendants(of window: NSWindow) {
        for child in window.childWindows ?? [] { closeDescendants(of: child); child.close() }
    }

    private static func displayDefinition(_ view: NSView, text: NSAttributedString, baseline: NSPoint) {
        // Nil options follow Dictionary preferences and can launch the Dictionary application.
        // The explicit public overlay option keeps lookup beside the word in the learning window.
        view.showDefinition(for: text, range: NSRange(location: 0, length: text.length),
            options: [.presentationType: NSView.DefinitionPresentationType.overlay],
            baselineOriginProvider: { _ in baseline })
    }
}

/// One lookup owns one source panel; it is never reused for another word. AppKit may attach
/// dictionary children after lookup was dismissed. This public hook rejects those late windows,
/// including when a newer lookup has already begun in a different source panel. No private
/// window class names, editor activation, or synthetic keyboard events are involved.
final class LearningDictionarySourcePanel: NSPanel {
    var allowsDictionaryWindows = false
    var onDictionaryWindow: ((NSWindow) -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
        super.addChildWindow(childWin, ordered: place)
        onDictionaryWindow?(childWin)
        guard !allowsDictionaryWindows else { return }
        childWin.orderOut(nil)
        // AppKit may order the window front after attaching it. Retain this rejected window until
        // the next main-actor job closes it outside that transaction; orderOut can detach its parent.
        Task { @MainActor [weak self] in
            // orderOut normally detaches the child. If AppKit reused it under another source
            // before this job ran, that newer owner now decides its lifetime.
            guard childWin.parent == nil || childWin.parent === self else { return }
            childWin.close()
        }
    }
}
