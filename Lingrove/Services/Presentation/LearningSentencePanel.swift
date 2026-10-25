import AppKit
import Combine
import Logging
import QuartzCore
import SwiftUI

/// Owns one nonactivating learning window and its dictionary panel. Updating its hosting
/// root preserves SwiftUI selection within a document; a new request ID resets that selection.
/// The window never becomes key, so showing, expanding or clicking learning content leaves typing
/// focus in the host editor. Its position follows the existing caret/selection geometry policy.
@MainActor
final class LearningSentencePanel: LearningSentencePresenting, LearningLookupPresenting {
    private let detailPanel: LearningDetailPanel
    private let speech: LearningSpeechController?
    private let vocabulary: VocabularyStore?
    private let windowAtPoint: (CGPoint) -> Int
    private let observesMouseEvents: Bool
    let explanation: LearningExplanationSession
    private let explanationService: LearningExplanationService?
    private var panel: NSPanel?
    private var hosting: NSHostingView<LearningSentenceCard>?
    private(set) var isVisible = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var dismissAction: (() -> Void)?
    private var clickMonitorsInstalled = false

    private var currentPresentation: LearningSentencePresentation?
    private var standaloneLookupID: UUID?
    private var layoutRevision = UUID()
    private var measurementSequence: UInt64 = 0
    private var reservedFrame: CGRect?
    private var contentSize: CGSize?
    private var reservationSubscription: AnyCancellable?

    /// App composition supplies only geometry, keeping translation independent of completion
    /// generation. A later completion can move this panel even when no new translation arrives.
    init(reservedFramePublisher: AnyPublisher<CGRect?, Never>? = nil,
         dictionaryProvider: (any LearningDictionaryProviding)? = nil,
         dictionarySettings: LearningDictionarySettings? = nil,
         speech: LearningSpeechController? = nil, vocabulary: VocabularyStore? = nil,
         explanationService: LearningExplanationService? = nil,
         observesMouseEvents: Bool = true,
         windowAtPoint: @escaping (CGPoint) -> Int = { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }) {
        self.speech = speech
        self.vocabulary = vocabulary
        self.windowAtPoint = windowAtPoint
        self.observesMouseEvents = observesMouseEvents
        self.explanationService = explanationService
        explanation = LearningExplanationSession(service: explanationService)
        detailPanel = LearningDetailPanel(provider: dictionaryProvider, dictionarySettings: dictionarySettings,
                                         speech: speech, vocabulary: vocabulary, explanationService: explanationService)
        reservationSubscription = reservedFramePublisher?.removeDuplicates().sink { [weak self] frame in
            guard let self else { return }
            self.reservedFrame = frame
            if self.currentPresentation != nil, let size = self.contentSize { self.layout(size: size) }
        }
    }

    var visibleFrame: CGRect? { isVisible ? panel?.frame : nil }
    var dictionarySession: LearningDictionarySession { detailPanel.dictionarySession }

    /// SwiftUI popovers are separate child windows. Treat their whole ancestor chain as part
    /// of the card: dismissing on mouse-down destroys the popover before its button's mouse-up
    /// can open the notebook or remove a saved usage.
    func owns(_ window: NSWindow?) -> Bool {
        var ancestor = window
        while let current = ancestor {
            if current === panel { return true }
            ancestor = current.parent
        }
        return detailPanel.owns(window)
    }

    /// The event adapter passes only a window identity, so the dismissal boundary can be tested
    /// without synthesizing global input or changing the frontmost application.
    func dismissForOutsideClick(in window: NSWindow?) {
        let inside = owns(window)
        logClick(route: "local", windowNumber: window?.windowNumber ?? 0, inside: inside)
        guard !inside else { return }
        dismissAction?()
    }

    func containsGlobalInteraction(at point: CGPoint) -> Bool {
        guard isVisible else { return false }
        let hit = windowAtPoint(point)
        let inside = LearningWindowInteraction.contains(point,
            roots: [panel] + detailPanel.interactionWindows,
            hitWindowNumber: hit)
        return inside
    }

    func dismissForGlobalClick(at point: CGPoint) {
        let hit = windowAtPoint(point)
        let inside = isVisible && LearningWindowInteraction.contains(point,
            roots: [panel] + detailPanel.interactionWindows, hitWindowNumber: hit)
        logClick(route: "global", windowNumber: hit, inside: inside)
        guard !inside else { return }
        dismissAction?()
    }

    /// Window IDs and the presentation ID explain a dismissal without recording the word,
    /// definition or host-window title. Only discrete clicks produce these debug events.
    private func logClick(route: String, windowNumber: Int, inside: Bool) {
        guard let currentPresentation else { return }
        LingroveLogger.learning.debug("Learning card click classified", metadata: [
            "stage": "card-click", "route": .string(route),
            "document_id": .string(currentPresentation.id.uuidString),
            "window_number": .stringConvertible(windowNumber), "inside": .stringConvertible(inside),
            "detail_windows": .string(detailPanel.interactionWindows.compactMap { $0 }
                .map { "\($0.windowNumber):\($0.isVisible):\($0.ignoresMouseEvents)" }.joined(separator: ","))
        ])
    }

    var favoriteCapture: VocabularyCapture? {
        guard isVisible else { return nil }
        if detailPanel.isVisible { return detailPanel.favoriteCapture }
        return currentPresentation.flatMap { VocabularyCaptureFactory.preview($0) }
    }

    /// Esc returns a component word to its expression, then closes the dictionary card, then
    /// the sentence pair. No synthetic keyboard events are sent to the host editor.
    func dismissDetail() -> Bool {
        if detailPanel.dismissDictionary() { return true }
        if standaloneLookupID != nil { return false }
        guard detailPanel.isVisible else { return false }
        detailPanel.hide()
        return true
    }

    /// Reading opens the existing dictionary card as its primary surface. The same owner
    /// still classifies native popovers/clicks and cancels the child session on dismissal.
    func showLookup(_ presentation: LearningLookupPresentation, validate: @escaping () -> Bool, dismiss: @escaping () -> Void) {
        hide()
        standaloneLookupID = presentation.id
        dismissAction = dismiss
        let capture = presentation.capture
        let ranges = capture.example?.ranges.map(\.nsRange) ?? [NSRange(location: 0, length: capture.expression.utf16.count)]
        let unit = LearningUnit(id: 0, surface: capture.expression, query: capture.dictionaryForm,
            kind: capture.kind == .word ? .word : .expression, ranges: ranges,
            words: LearningUnitPolicy.words(in: capture.example?.text ?? capture.expression, language: capture.language)
                .filter { word in ranges.contains { NSIntersectionRange($0, word.range).length > 0 } })
        let screen = NSScreen.screens.first { $0.frame.intersects(presentation.anchor) } ?? NSScreen.main
        LearningRequestTrace.$requestID.withValue(presentation.traceID) {
            detailPanel.show(unit, documentID: presentation.id, language: capture.language,
                placement: .init(parent: presentation.anchor, caret: presentation.anchor, reserved: reservedFrame,
                    screen: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600),
                    anchorY: presentation.anchor.maxY, standalone: true),
                speechContext: capture.example?.text, vocabularyCapture: capture, translationLanguage: presentation.translationLanguage,
                validateCapture: validate, dismiss: dismiss)
        }
        isVisible = detailPanel.isVisible
        installClickMonitors()
    }

    func toggleLookupDetails() { detailPanel.toggleDetails() }

    func hide() {
        standaloneLookupID = nil
        explanation.clear()
        if let documentID = currentPresentation?.id { speech?.stop(ownerID: documentID) }
        isVisible = false
        detailPanel.hide()
        panel?.alphaValue = 1
        panel?.orderOut(nil)
        panel?.contentView = nil
        hosting = nil
        dismissAction = nil
        currentPresentation = nil
        contentSize = nil
        layoutRevision = UUID()
        clickMonitorsInstalled = false
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor); self.localMouseMonitor = nil }
    }

    func show(_ presentation: LearningSentencePresentation, expand: @escaping () -> Void, dismiss: @escaping () -> Void) {
        show(presentation, expand: expand, dismiss: dismiss, replace: nil)
    }

    func show(
        _ presentation: LearningSentencePresentation, expand: @escaping () -> Void, dismiss: @escaping () -> Void,
        replace: (() -> Void)?
    ) {
        if let currentPresentation,
           currentPresentation.id != presentation.id || presentation.isStale || currentPresentation.source != presentation.source {
            // Source/document changes invalidate every target owned by the old preview.
            speech?.stop(ownerID: currentPresentation.id)
        } else if let currentPresentation, currentPresentation.translation != presentation.translation {
            speech?.stop(target: SpeechTarget(ownerID: currentPresentation.id, itemID: "preview.translation"))
        }
        if presentation.isStale { speech?.stop(ownerID: presentation.id) }
        if detailPanel.dictionarySession.documentID != nil,
           detailPanel.dictionarySession.documentID != presentation.id || presentation.isStale ||
            currentPresentation?.translation != presentation.translation || currentPresentation?.isExpanded != presentation.isExpanded {
            detailPanel.hide()
        }
        currentPresentation = presentation
        explanation.setTarget(LearningExplanationPolicy.input(presentation))
        let revision = UUID()
        layoutRevision = revision
        let card = LearningSentenceCard(
            presentation: presentation, explanation: explanationService == nil ? nil : explanation,
            replace: replace,
            expand: expand, dismiss: dismiss,
            lookupText: { [weak self] anchor, view in
                self?.inspectInlineWord(anchor, documentID: presentation.id, view: view)
            },
            lookupUnit: { [weak self] anchor, view in
                self?.inspectUnit(anchor, documentID: presentation.id, view: view)
            },
            speech: speech,
            vocabulary: vocabulary,
            sizeChanged: { [weak self] size in
                self?.scheduleLayout(size: size, revision: revision)
            }
        )
        let window = panel ?? LearningSentenceWindow(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        if let hosting, hosting.rootView.presentation.id == presentation.id {
            hosting.rootView = card
        } else {
            let view = NSHostingView(rootView: card)
            hosting = view
            window.contentView = view
        }
        panel = window
        window.title = String(localized: "Expression Learning", table: "Learning",
            comment: "Accessibility and window title for the read-only sentence-learning panel.")
        dismissAction = dismiss
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        hosting?.layoutSubtreeIfNeeded()
        if let size = hosting?.fittingSize { layout(size: size) }
        installClickMonitors()
    }

    /// Unit identity, source geometry and the fixed sentence are validated together. A fallback
    /// word click remains useful while recognition is pending; later recognition cannot change it.
    private func inspectUnit(_ anchor: LearningUnitTextAnchor, documentID: UUID, view: NSTextView) {
        guard let current = currentPresentation, current.id == documentID, !current.isStale,
              let textView = view as? LearningDictionaryTextView, view.window === panel,
              let parent = visibleFrame else { return }
        let original = textView.source
        let text = original ? current.source : current.translation
        let language = original ? current.sourceLanguage : current.targetLanguage
        guard view.string == text else { return }
        let units = original || current.units.isEmpty
            ? LearningUnitPolicy.fallback(in: text, language: language) : current.units
        guard units.contains(anchor.unit) else { return }
        let anchorFrame = view.window!.convertToScreen(view.convert(anchor.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.intersects(parent) } ?? NSScreen.main
        detailPanel.show(anchor.unit, documentID: current.id, language: language,
            placement: .init(parent: parent, caret: current.caret, reserved: reservedFrame,
                screen: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600), anchorY: anchorFrame.maxY + 12),
            speechContext: text,
            vocabularyCapture: VocabularyCaptureFactory.unit(anchor.unit, in: current, original: original))
    }

    private func inspectInlineWord(_ anchor: LearningDictionaryTextAnchor, documentID: UUID, view: NSTextView) {
        guard let current = currentPresentation, current.id == documentID, !current.isStale,
              !current.isExpanded, view.window === panel, view.string == current.translation,
              LearningDictionaryWordPolicy.word(atUTF16Location: anchor.word.range.location, in: current.translation,
                  language: current.targetLanguage.naturalLanguage) == anchor.word else { return }
        guard let window = view.window else { return }
        showWord(anchor.word, in: current, anchor: window.convertToScreen(view.convert(anchor.bounds, to: nil)))
    }

    private func showWord(_ word: LearningDictionaryWord, in current: LearningSentencePresentation, anchor: CGRect) {
        guard let parent = visibleFrame else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(parent) } ?? NSScreen.main
        let unit = LearningUnit.word(word)
        detailPanel.show(unit, documentID: current.id, language: current.targetLanguage,
            placement: .init(parent: parent, caret: current.caret, reserved: reservedFrame,
                screen: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600), anchorY: anchor.maxY + 12),
            speechContext: current.translation, vocabularyCapture: VocabularyCaptureFactory.unit(unit, in: current))
    }

    /// Preferences arrive during SwiftUI layout/commit. Changing an AppKit window there can start
    /// a nested transaction, so resize on a later main-actor job. A sequence rejects an older size
    /// even if several measurements arrive before that job runs; the document revision rejects
    /// jobs from a closed or replaced card.
    private func scheduleLayout(size: CGSize, revision: UUID) {
        guard layoutRevision == revision, currentPresentation != nil,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        measurementSequence &+= 1
        let sequence = measurementSequence
        Task { @MainActor [weak self] in
            guard let self, self.layoutRevision == revision, self.measurementSequence == sequence,
                  self.currentPresentation != nil else { return }
            self.layout(size: size)
        }
    }

    /// The view supplies its measured size rather than duplicating dimensions in two layers.
    /// Revision checks above discard queued measurements from a replaced or hidden card.
    private func layout(size: CGSize) {
        guard let presentation = currentPresentation, let panel,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let caret = presentation.caret
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        let size = CGSize(width: ceil(size.width), height: ceil(size.height))
        contentSize = size
        guard let frame = LearningSentencePanelLayout.frame(caretRect: caret, contentSize: size,
            visibleFrame: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600), reservedFrame: reservedFrame) else {
            // Retain the document and its size while space is unavailable. The geometry stream
            // can show it again when completion moves or disappears; no model request is repeated.
            panel.orderOut(nil)
            isVisible = false
            speech?.stop(ownerID: presentation.id)
            updateDetailParent(nil, presentation: presentation, screen: screen)
            return
        }
        let previousFrame = panel.frame
        panel.setFrame(frame, display: true)
        if panel.frame != previousFrame || !isVisible {
            // Compare requested and actual AppKit geometry without recording editor text. These
            // events distinguish a stale anchor from a hosting-view resize or obstacle fallback.
            LingroveLogger.learning.debug("Translation preview positioned", metadata: [
                "stage": "preview-layout",
                "caret_rect": .string(NSStringFromRect(caret)),
                "requested_frame": .string(NSStringFromRect(frame)),
                "panel_frame": .string(NSStringFromRect(panel.frame)),
                "reserved_frame": .string(reservedFrame.map(NSStringFromRect) ?? "none"),
                "screen_frame": .string(NSStringFromRect(screen?.visibleFrame ?? .zero))
            ])
        }
        let wasVisible = isVisible && panel.isVisible
        isVisible = true
        if !panel.isVisible {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if !wasVisible && !reduceMotion {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                    panel.animator().alphaValue = 1
                }
            } else {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
        }
        updateDetailParent(panel.frame, presentation: presentation, screen: screen)
    }

    private func updateDetailParent(_ frame: CGRect?, presentation: LearningSentencePresentation, screen: NSScreen?) {
        detailPanel.updateParent(frame, caret: presentation.caret, reserved: reservedFrame,
            screen: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    /// Some chat hosts reuse the same AX field and metadata after navigation. An outside click
    /// invalidates the display even before the next AX observation can identify the new context.
    private func installClickMonitors() {
        // Window fixtures drive the same dismissal methods directly. Live desktop input must
        // not close a fixture while the user continues working in another application.
        guard observesMouseEvents, !clickMonitorsInstalled else { return }
        clickMonitorsInstalled = true
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismissForGlobalClick(at: LearningWindowInteraction.screenPoint(for: event))
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismissForOutsideClick(in: event.window)
            }
            return event
        }
    }
}

private final class LearningSentenceWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
