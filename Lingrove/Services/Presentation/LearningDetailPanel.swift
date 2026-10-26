import AppKit
import SwiftUI

/// Owned once by the sentence panel. This nonactivating sibling owns one expression/word dictionary
/// session. Every source and component
/// word is rendered in this same window, so favorite menus never straddle a system-owned popup.
@MainActor
final class LearningDetailPanel {
    let dictionarySession: LearningDictionarySession
    private let speech: LearningSpeechController?
    private let vocabulary: VocabularyStore?
    private var panel: NSPanel?
    private var hosting: NSHostingView<LearningDictionaryCard>?
    private var layoutRevision = UUID()
    private var measurementSequence: UInt64 = 0
    private var contentSize: CGSize?
    private var parentFrame: CGRect?
    private var standalone = false
    private var dismissAction: (() -> Void)?
    private var caretRect = CGRect.zero
    private var reservedFrame: CGRect?
    private var screen = CGRect.zero
    private var anchorY: CGFloat = 0
    private var anchorOffsetFromTop: CGFloat = 0
    // This is the lookup's original side/top anchor, not its latest resized frame. If expansion
    // needs a screen-edge clamp, collapsing must still return to the original reading position.
    private var placementFrame: CGRect?
    private var popupWindows = LearningPopupWindowRegistry()
    private(set) var isVisible = false

    init(provider: (any LearningDictionaryProviding)? = nil, dictionarySettings: LearningDictionarySettings? = nil,
         speech: LearningSpeechController? = nil, vocabulary: VocabularyStore? = nil,
         explanationService: LearningExplanationService? = nil) {
        self.speech = speech
        self.vocabulary = vocabulary
        dictionarySession = LearningDictionarySession(provider: provider ?? LearningLexiconService(
            resourceURL: Bundle.main.url(forResource: "learning-expressions", withExtension: "json")),
            settings: dictionarySettings, explanationService: explanationService)
    }

    var visibleFrame: CGRect? { isVisible ? panel?.frame : nil }
    var interactionWindows: [NSWindow?] { [panel] + popupWindows.windows.map(Optional.some) }
    var favoriteCapture: VocabularyCapture? {
        guard isVisible else { return nil }
        return dictionarySession.favoriteCapture
    }
    func owns(_ window: NSWindow?) -> Bool {
        if popupWindows.owns(window) { return true }
        // Dictionary popovers can have nested child windows. An ancestor check makes clicking
        // their content an internal interaction without depending on AppKit's private types.
        var ancestor = window
        while let current = ancestor {
            if current === panel { return true }
            ancestor = current.parent
        }
        return false
    }

    func dismissDictionary() -> Bool {
        guard dictionarySession.isRelatedEntry else { return false }
        stopCurrentSpeech()
        dictionarySession.returnToExpression()
        return true
    }

    func show(_ unit: LearningUnit, documentID: UUID, language: LearningLanguage?,
              placement: LearningDetailPlacement, speechContext: String? = nil,
              vocabularyCapture: VocabularyCapture? = nil, translationLanguage: LearningLanguage? = nil,
              validateCapture: @escaping () -> Bool = { true }, dismiss: (() -> Void)? = nil) {
        stopCurrentSpeech()
        standalone = placement.standalone
        dismissAction = dismiss
        dictionarySession.open(unit, documentID: documentID, language: language, speechContext: speechContext,
            vocabularyCapture: vocabularyCapture, translationLanguage: translationLanguage, validateCapture: validateCapture)
        anchorY = placement.anchorY
        anchorOffsetFromTop = placement.parent.maxY - placement.anchorY
        layoutRevision = UUID()
        placementFrame = nil
        popupWindows.reset()
        popupWindows = LearningPopupWindowRegistry()
        let revision = layoutRevision
        let card = LearningDictionaryCard(session: dictionarySession, close: { [weak self] in
            guard let self else { return }
            if let dismiss = self.dismissAction { dismiss() } else { self.hide() }
        },
            sizeChanged: { [weak self] in self?.scheduleLayout($0, revision: revision) },
            lookup: { [weak self] word, button in
                self?.selectDictionaryTerm(word, from: button, unit: unit, documentID: documentID)
            },
            speech: speech, vocabulary: vocabulary,
            lookupWord: { [weak self] word, button in
                self?.selectDictionaryWord(word, from: button, unit: unit, documentID: documentID)
            }, popupWindows: popupWindows)
        let window = panel ?? LearningDetailWindow(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Reuse the NSPanel, but not a previous lookup's SwiftUI state. An open favorite/source
        // popover must be torn down before this window starts showing a different capture.
        let view = NSHostingView(rootView: card)
        hosting = view
        window.contentView = view
        panel = window
        window.title = String(localized: "Expression Dictionary", table: "Learning",
            comment: "Window title for the learning dictionary panel.")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        hosting?.layoutSubtreeIfNeeded()
        contentSize = hosting?.fittingSize
        updateParent(placement.parent, caret: placement.caret, reserved: placement.reserved, screen: placement.screen)
    }

    func updateParent(_ parent: CGRect?, caret: CGRect, reserved: CGRect?, screen: CGRect) {
        if parent == nil { placementFrame = nil }
        if let previous = parentFrame, let parent, let frame = placementFrame {
            placementFrame = frame.offsetBy(dx: parent.minX - previous.minX, dy: parent.maxY - previous.maxY)
        }
        parentFrame = parent
        // The parent may move to avoid a completion that arrives later. Keep the selected point
        // relative to the card rather than retaining an obsolete absolute mouse position.
        if let parent { anchorY = parent.maxY - anchorOffsetFromTop }
        caretRect = caret
        reservedFrame = reserved
        self.screen = screen
        layout()
    }

    /// Immutable document/unit identities reject controls from an older rendered sentence. A
    /// string-only legacy control may navigate only an unambiguous occurrence; new controls
    /// carry the exact word range so repeated words retain their distinct example highlights.
    func selectDictionaryTerm(_ term: String, from button: NSButton, unit: LearningUnit, documentID: UUID) {
        guard isVisible, dictionarySession.documentID == documentID, dictionarySession.unit == unit,
              button.window === panel else { return }
        let words = unit.words.filter { $0.text == term }
        guard words.count == 1 else { return }
        stopCurrentSpeech()
        dictionarySession.select(words[0])
    }

    func selectDictionaryWord(_ word: LearningDictionaryWord, from button: NSButton, unit: LearningUnit, documentID: UUID) {
        guard isVisible, dictionarySession.documentID == documentID, dictionarySession.unit == unit,
              button.window === panel, unit.words.contains(word) else { return }
        stopCurrentSpeech()
        dictionarySession.select(word)
    }

    /// Document replacement and full dismissal retire the session and any pending lookup.
    func hide() {
        popupWindows.reset()
        stopCurrentSpeech()
        dictionarySession.close()
        dismissAction = nil
        standalone = false
        layoutRevision = UUID()
        parentFrame = nil
        contentSize = nil
        placementFrame = nil
        isVisible = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        hosting = nil
    }

    /// Closing one dictionary target stops only its utterance. A sentence's source or translation
    /// may continue reading while the user closes or changes the separate detail panel.
    private func stopCurrentSpeech() {
        guard let documentID = dictionarySession.documentID else { return }
        speech?.stop(target: SpeechTarget(ownerID: documentID, itemID: "detail.\(dictionarySession.query)"))
    }

    /// Geometry preferences are delivered during view layout. Queue only the latest valid size
    /// outside that transaction, and reject callbacks from a closed or changed meaning unit.
    private func scheduleLayout(_ size: CGSize, revision: UUID) {
        guard layoutRevision == revision, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        measurementSequence &+= 1
        let sequence = measurementSequence
        Task { @MainActor [weak self] in
            guard let self, self.layoutRevision == revision, self.measurementSequence == sequence,
                  self.dictionarySession.unit != nil else { return }
            self.contentSize = size
            self.layout()
        }
    }

    func toggleDetails() {
        dictionarySession.explanation.toggleLookupDetails()
    }

    /// Standalone lookup uses the same caret exclusion policy as sentence previews. Resizing
    /// first preserves its top edge, keeping the target/meaning stationary while details expand.
    private func standaloneFrame(_ size: CGSize) -> CGRect? {
        if let previous = placementFrame {
            let frame = CGRect(x: previous.minX, y: previous.maxY - size.height, width: size.width, height: size.height)
            if screen.contains(frame), !frame.intersects(caretRect.insetBy(dx: -8, dy: -8)),
               !(reservedFrame?.intersects(frame.insetBy(dx: -8, dy: -8)) ?? false) { return frame }
        }
        let frame = LearningSentencePanelLayout.frame(caretRect: caretRect, contentSize: size,
            visibleFrame: screen, reservedFrame: reservedFrame)
        placementFrame = frame
        return frame
    }

    private func layout() {
        guard dictionarySession.unit != nil, let panel, let parentFrame, let size = contentSize else {
            stopCurrentSpeech()
            self.panel?.orderOut(nil)
            isVisible = false
            return
        }
        let measured = CGSize(width: ceil(size.width), height: ceil(size.height))
        if standalone {
            guard let frame = standaloneFrame(measured) else { panel.orderOut(nil); isVisible = false; return }
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            isVisible = true
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        let obstacles = [LearningDetailPanelLayout.protectedTextRect(caretRect, screen: screen)] +
            (reservedFrame.map { [$0] } ?? [])
        if placementFrame == nil {
            // HTML is measured after WebKit paints. Choose a side with room for the bounded
            // definition viewport before that paint, without reserving blank space in the UI.
            placementFrame = LearningDetailPanelLayout.frame(parent: parentFrame, anchorY: anchorY,
                size: CGSize(width: measured.width, height: max(measured.height, 480)), screen: screen, obstacles: obstacles)
        }
        guard let frame = LearningDetailPanelLayout.frame(parent: parentFrame, anchorY: anchorY,
                size: measured, screen: screen, obstacles: obstacles, preferred: placementFrame) else {
            stopCurrentSpeech()
            panel.orderOut(nil)
            isVisible = false
            return
        }
        if placementFrame == nil { placementFrame = frame }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        isVisible = true
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

private final class LearningDetailWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
