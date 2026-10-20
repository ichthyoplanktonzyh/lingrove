import AppKit
import Combine
import Logging
import SwiftUI

/// Owns one nonactivating learning window and its correspondence panel. Updating its hosting
/// root preserves SwiftUI selection within a document; a new request ID resets that selection.
/// The window never becomes key, so showing, expanding or clicking learning content leaves typing
/// focus in the host editor. Its position follows the existing caret/selection geometry policy.
@MainActor
final class LearningSentencePanel: LearningSentencePresenting {
    private let detailPanel: LearningDetailPanel
    private let sentenceDictionary: LearningSystemDictionaryPresenter
    private let speech: LearningSpeechController?
    private let vocabulary: VocabularyStore?
    private let windowAtPoint: (CGPoint) -> Int
    private var panel: NSPanel?
    private var hosting: NSHostingView<LearningSentenceCard>?
    private(set) var isVisible = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var dismissAction: (() -> Void)?
    private var clickMonitorsInstalled = false

    private var currentPresentation: LearningSentencePresentation?
    private var layoutRevision = UUID()
    private var measurementSequence: UInt64 = 0
    private var reservedFrame: CGRect?
    private var contentSize: CGSize?
    private var reservationSubscription: AnyCancellable?

    /// App composition supplies only geometry, keeping translation independent of completion
    /// generation. A later completion can move this panel even when no new translation arrives.
    init(reservedFramePublisher: AnyPublisher<CGRect?, Never>? = nil,
         dictionary: LearningSystemDictionaryPresenter? = nil,
         dictionaryProvider: (any LearningDictionaryProviding)? = nil,
         speech: LearningSpeechController? = nil, vocabulary: VocabularyStore? = nil,
         windowAtPoint: @escaping (CGPoint) -> Int = { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }) {
        // Default arguments are evaluated by the caller, outside this actor-isolated body.
        // Construct the AppKit collaborator here so its initialization always stays on MainActor.
        sentenceDictionary = dictionary ?? LearningSystemDictionaryPresenter()
        self.speech = speech
        self.vocabulary = vocabulary
        self.windowAtPoint = windowAtPoint
        detailPanel = LearningDetailPanel(provider: dictionaryProvider, speech: speech, vocabulary: vocabulary)
        reservationSubscription = reservedFramePublisher?.removeDuplicates().sink { [weak self] frame in
            guard let self else { return }
            self.reservedFrame = frame
            if self.currentPresentation != nil, let size = self.contentSize { self.layout(size: size) }
        }
    }

    var visibleFrame: CGRect? { isVisible ? panel?.frame : nil }
    var detailState: LearningDetailState { detailPanel.state }

    /// SwiftUI popovers are separate child windows. Treat their whole ancestor chain as part
    /// of the card: dismissing on mouse-down destroys the popover before its button's mouse-up
    /// can open the notebook or remove a saved usage.
    func owns(_ window: NSWindow?) -> Bool {
        var ancestor = window
        while let current = ancestor {
            if current === panel { return true }
            ancestor = current.parent
        }
        return detailPanel.owns(window) || sentenceDictionary.owns(window)
    }

    /// The event adapter passes only a window identity, so the dismissal boundary can be tested
    /// without synthesizing global input or changing the frontmost application.
    func dismissForOutsideClick(in window: NSWindow?) {
        sentenceDictionary.recordInteraction(kind: "local-mouse-down", window: window)
        detailPanel.recordDictionaryInteraction(kind: "local-mouse-down", window: window)
        guard !owns(window) else { return }
        dismissAction?()
    }

    func containsGlobalInteraction(at point: CGPoint) -> Bool {
        guard isVisible else { return false }
        let hit = windowAtPoint(point)
        let inside = LearningWindowInteraction.contains(point,
            roots: [panel] + detailPanel.interactionWindows + sentenceDictionary.interactionWindows,
            hitWindowNumber: hit)
        sentenceDictionary.recordInteraction(kind: "global-hit", window: nil, hitWindowNumber: hit)
        detailPanel.recordDictionaryInteraction(kind: "global-hit", window: nil, hitWindowNumber: hit)
        return inside
    }

    func dismissForGlobalClick(at point: CGPoint) {
        let internalClick = containsGlobalInteraction(at: point)
        let kind = internalClick ? "global-mouse-down.internal" : "global-mouse-down.external"
        sentenceDictionary.recordInteraction(kind: kind, window: nil)
        detailPanel.recordDictionaryInteraction(kind: kind, window: nil)
        guard !internalClick else { return }
        dismissAction?()
    }

    var favoriteCapture: VocabularyCapture? {
        guard isVisible else { return nil }
        if let capture = sentenceDictionary.vocabularyCapture { return capture }
        if detailPanel.isVisible { return detailPanel.favoriteCapture }
        return currentPresentation.flatMap { VocabularyCaptureFactory.preview($0) }
    }

    /// Esc closes native lookup, then the correspondence detail, then the sentence pair. Generated content
    /// survives the first two steps, and the system receives no synthetic keyboard events.
    func dismissDetail() -> Bool {
        if sentenceDictionary.dismiss() { return true }
        if detailPanel.dismissDictionary() { return true }
        guard detailPanel.isVisible else { return false }
        detailPanel.hide()
        sentenceDictionary.dismiss()
        return true
    }

    func hide() {
        if let documentID = currentPresentation?.id { speech?.stop(ownerID: documentID) }
        isVisible = false
        sentenceDictionary.dismiss(reason: "preview-hidden")
        detailPanel.hide()
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
        // Compact word lookup remains anchored to the same fixed translation while analysis
        // streams in. Dismiss when its text/view mode changes, rather than on every chunk update.
        if currentPresentation?.id != presentation.id || presentation.isStale ||
            currentPresentation?.translation != presentation.translation ||
            currentPresentation?.isExpanded != presentation.isExpanded {
            sentenceDictionary.dismiss(reason: "preview-updated")
        }
        if detailPanel.dictionarySession.documentID != nil,
           detailPanel.dictionarySession.documentID != presentation.id || presentation.isStale ||
            currentPresentation?.translation != presentation.translation || currentPresentation?.isExpanded != presentation.isExpanded {
            detailPanel.hide()
        }
        if let selection = detailPanel.state.chunk,
           selection.documentID != presentation.id || !presentation.isExpanded || presentation.isStale ||
            !presentation.chunks.contains(where: { chunk in
                chunk.id == selection.chunkID &&
                LearningChunkDisplay.quote(presentation.source, ranges: chunk.sourceRanges) == selection.source &&
                LearningChunkDisplay.quote(presentation.translation, ranges: chunk.targetRanges) == selection.target
            }) {
            // Background alignment updates do not discard an open dictionary for the same text.
            detailPanel.state.chunk = nil
        }
        currentPresentation = presentation
        let revision = UUID()
        layoutRevision = revision
        let card = LearningSentenceCard(
            presentation: presentation, detailState: detailPanel.state, replace: replace,
            inspect: { [weak self] in self?.selectCorrespondence($0, documentID: presentation.id) }, expand: expand, dismiss: dismiss,
            lookup: { [weak self] word, button in self?.inspectWord(word, documentID: presentation.id, button: button) },
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

    private func selectCorrespondence(_ identifier: Int, documentID: UUID) {
        guard let current = currentPresentation, current.id == documentID, !current.isStale,
              let chunk = current.chunks.first(where: { $0.id == identifier }) else { return }
        detailPanel.selectCorrespondence(detail(chunk, presentation: current))
    }

    /// Unit identity, source geometry and the fixed sentence are validated together. A fallback
    /// word click remains useful while recognition is pending; later alignment cannot change it.
    private func inspectUnit(_ anchor: LearningUnitTextAnchor, documentID: UUID, view: NSTextView) {
        guard let current = currentPresentation, current.id == documentID, !current.isStale,
              view.window === panel, view.string == current.translation,
              let parent = visibleFrame else { return }
        let units = current.units.isEmpty
            ? LearningUnitPolicy.fallback(in: current.translation, language: current.targetLanguage) : current.units
        guard units.contains(anchor.unit) else { return }
        if anchor.unit.kind == .word {
            // Native presentation preserves pronunciation, word classes, senses and examples.
            // A single word never opens our expression card or requests flattened system text.
            detailPanel.hide(preservingCorrespondence: true)
            sentenceDictionary.show(anchor.unit.query, from: view, textBounds: anchor.bounds, font: anchor.font,
                vocabulary: vocabulary, capture: VocabularyCaptureFactory.unit(anchor.unit, in: current))
            return
        }
        sentenceDictionary.dismiss()
        let anchorFrame = view.window!.convertToScreen(view.convert(anchor.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.intersects(parent) } ?? NSScreen.main
        detailPanel.show(anchor.unit, documentID: current.id, language: current.targetLanguage,
            // A unit can cross multiple colors. Dictionary lookup must not choose a meaning
            // group from its extent or replace the group selected by a preceding single click.
            correspondence: detailPanel.state.chunk,
            placement: .init(parent: parent, caret: current.caret, reserved: reservedFrame,
                screen: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600), anchorY: anchorFrame.maxY + 12),
            speechContext: current.translation, vocabularyCapture: VocabularyCaptureFactory.unit(anchor.unit, in: current))
    }

    private func detail(_ chunk: LearningMeaningChunk, presentation: LearningSentencePresentation) -> LearningChunkDetail {
        let target = LearningChunkDisplay.quote(presentation.translation, ranges: chunk.targetRanges)
        return .init(documentID: presentation.id, chunkID: chunk.id,
            source: LearningChunkDisplay.quote(presentation.source, ranges: chunk.sourceRanges), target: target,
            language: presentation.targetLanguage, words: LearningChunkDisplay.words(in: target, language: presentation.targetLanguage))
    }

    /// Lookup needs only the fixed target sentence. It works while analysis is disabled, pending
    /// or failed; button/window/document checks reject a callback from an old rendered sentence.
    private func inspectWord(_ word: String, documentID: UUID, button: NSButton) {
        guard let current = currentPresentation, current.id == documentID, current.isExpanded, !current.isStale,
              button.window === panel,
              LearningChunkDisplay.words(in: current.translation, language: current.targetLanguage).contains(word) else { return }
        let words = LearningUnitPolicy.words(in: current.translation, language: current.targetLanguage).filter { $0.text == word }
        let capture = words.count == 1 ? VocabularyCaptureFactory.unit(.word(words[0]), in: current) : nil
        sentenceDictionary.show(word, from: button, vocabulary: vocabulary, capture: capture)
    }

    private func inspectInlineWord(_ anchor: LearningDictionaryTextAnchor, documentID: UUID, view: NSTextView) {
        guard let current = currentPresentation, current.id == documentID, !current.isStale,
              !current.isExpanded, view.window === panel, view.string == current.translation,
              LearningDictionaryWordPolicy.word(atUTF16Location: anchor.word.range.location, in: current.translation,
                  language: current.targetLanguage.naturalLanguage) == anchor.word else { return }
        sentenceDictionary.show(anchor.word.text, from: view, textBounds: anchor.bounds, font: anchor.font,
            vocabulary: vocabulary, capture: VocabularyCaptureFactory.unit(.word(anchor.word), in: current))
    }

    /// The click carries only a validated meaning ID; the current document supplies its quotes
    /// so a stale view cannot query a term from a replaced sentence.
    func inspectChunk(_ identifier: Int, documentID: UUID) {
        guard let presentation = currentPresentation, presentation.isExpanded, !presentation.isStale,
              presentation.id == documentID,
              let chunk = presentation.chunks.first(where: { $0.id == identifier }), let parent = visibleFrame else { return }
        let target = LearningChunkDisplay.quote(presentation.translation, ranges: chunk.targetRanges)
        let detail = LearningChunkDetail(documentID: presentation.id, chunkID: identifier,
            source: LearningChunkDisplay.quote(presentation.source, ranges: chunk.sourceRanges), target: target,
            language: presentation.targetLanguage,
            words: LearningChunkDisplay.words(in: target, language: presentation.targetLanguage))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.intersects(parent) } ?? NSScreen.main
        let unit = LearningUnit(id: identifier, surface: target, query: target, kind: .expression,
            ranges: chunk.targetRanges, words: LearningUnitPolicy.words(in: presentation.translation, language: presentation.targetLanguage)
                .filter { word in chunk.targetRanges.contains { NSIntersectionRange($0, word.range).length == word.range.length } })
        detailPanel.show(unit, documentID: presentation.id, language: presentation.targetLanguage, correspondence: detail,
            placement: LearningDetailPlacement(parent: parent, caret: presentation.caret, reserved: reservedFrame,
            screen: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600),
            anchorY: parent.contains(mouse) ? mouse.y + 18 : parent.maxY), speechContext: presentation.translation,
            vocabularyCapture: VocabularyCaptureFactory.unit(unit, in: presentation))
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
            sentenceDictionary.dismiss()
            updateDetailParent(nil, presentation: presentation, screen: screen)
            return
        }
        let previousFrame = panel.frame
        panel.setFrame(frame, display: true)
        if panel.frame != previousFrame || !isVisible {
            // Compare requested and actual AppKit geometry without recording editor text. These
            // events distinguish a stale anchor from a hosting-view resize or obstacle fallback.
            CotabbyLogger.learning.debug("Translation preview positioned", metadata: [
                "stage": "preview-layout",
                "caret_rect": .string(NSStringFromRect(caret)),
                "requested_frame": .string(NSStringFromRect(frame)),
                "panel_frame": .string(NSStringFromRect(panel.frame)),
                "reserved_frame": .string(reservedFrame.map(NSStringFromRect) ?? "none"),
                "screen_frame": .string(NSStringFromRect(screen?.visibleFrame ?? .zero))
            ])
        }
        isVisible = true
        if !panel.isVisible { panel.orderFrontRegardless() }
        updateDetailParent(panel.frame, presentation: presentation, screen: screen)
    }

    private func updateDetailParent(_ frame: CGRect?, presentation: LearningSentencePresentation, screen: NSScreen?) {
        detailPanel.updateParent(frame, caret: presentation.caret, reserved: reservedFrame,
            screen: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    /// Some chat hosts reuse the same AX field and metadata after navigation. An outside click
    /// invalidates the display even before the next AX observation can identify the new context.
    private func installClickMonitors() {
        guard !clickMonitorsInstalled else { return }
        clickMonitorsInstalled = true
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismissForGlobalClick(at: event.locationInWindow)
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
