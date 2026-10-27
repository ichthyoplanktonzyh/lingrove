import AppKit
import Combine
import Logging

/// Owns one key-capable input panel and a separate non-key candidate panel. Typing belongs to a
/// real NSTextView (including IME marked text), while candidate clicks never move the insertion
/// point. The input temporarily activates Lingrove to establish system keyboard/IME ownership;
/// its borderless appearance stays at the host caret. Hiding explicitly returns the original app
/// only if this input still owns focus. Neither window inserts temporary query text in the host.
@MainActor
final class ExpressionAssistPanelController: NSObject, ExpressionAssistPresenting, NSTextViewDelegate, NSWindowDelegate {
    private typealias Metrics = ExpressionAssistLayout.Metrics
    var onQueryChanged: ((String, Bool) -> Void)?
    var onSubmit: (() -> Void)?
    var onAccept: ((ExpressionAssistCandidate) -> Void)?
    var onCancel: (() -> Void)?
    var onDismissed: (() -> Void)?
    var speech: LearningSpeechController?
    var vocabulary: VocabularyStore?
    private var inputPanel: ExpressionAssistInputPanel?
    private var candidatePanel: ExpressionAssistResultPanel?
    private var queryView: ExpressionAssistQueryView?
    private var queryScroll: NSScrollView?
    private var context: FocusedInputSnapshot?
    private var request: ExpressionAssistRequest?
    private var result: ExpressionAssistResult?
    private var message: String?
    private var loading = false
    private var selected = 0
    private var quiet = true
    private var closing = false
    private var localMouse: Any?
    private var globalMouse: Any?
    private var font = NSFont.systemFont(ofSize: 14)
    private var screenFrame = CGRect.zero
    private var failedText = ""
    private weak var failureCopyButton: NSButton?
    private var lastQuery: String?
    private var lastComposing = false
    private var layoutTask: Task<Void, Never>?
    private var renderedCandidates: CandidateState?
    private var lineHeight: CGFloat = 0
    private var hostBaseline: CGFloat = 0
    private var nativeBaseline: CGFloat = 0
    private var sessionID = UUID()
    private var toolSubscriptions = Set<AnyCancellable>()
    /// Content-free work counters let native regression tests enforce coalescing and view reuse.
    private(set) var inputLayoutPasses = 0
    private(set) var candidateBuilds = 0

    /// A window-lifetime rendering receipt, independent of query text. Composition changes only
    /// visibility; only different content or action state rebuilds the candidate views.
    private struct CandidateState: Equatable {
        let result: ExpressionAssistResult?
        let message: String?
        let loading: Bool
        let selected: Int
        let quiet: Bool
        let speakingIndex: Int?
        let savedIndices: Set<Int>
        let savingIndices: Set<Int>
    }
    var isVisible: Bool { inputPanel?.isVisible == true }
    var hasKeyFocus: Bool { isVisible && NSApp.isActive && inputPanel?.isKeyWindow == true }

    /// Exposes the currently selected candidate as a vocabulary capture so the global vocabulary
    /// shortcut can collect an expression directly while the candidate list is open.
    var favoriteCapture: VocabularyCapture? {
        guard isVisible, let candidates = result?.candidates, candidates.indices.contains(selected) else { return nil }
        return capture(for: candidates[selected])
    }

    func show(context: FocusedInputSnapshot, trigger: String, initialQuery: String) async {
        hide(restoringHost: false)
        self.context = context
        sessionID = UUID()
        closing = false
        let renderer: GhostBaselinePolicy.HostRenderer = context.isWebContentField ? .webEngine : .textKit
        font = GhostFontResolver.resolve(.init(style: context.resolvedFieldStyle, hostMetrics: context.hostTextMetrics,
            caretBoxHeight: context.caretRect.height, renderer: renderer)).font
        let metrics = NSLayoutManager()
        lineHeight = metrics.defaultLineHeight(for: font)
        nativeBaseline = metrics.defaultBaselineOffset(for: font)
        hostBaseline = GhostBaselinePolicy.baselineOffsetFromTop(font: font,
            boxHeight: context.caretRect.height, renderer: renderer)
        let screen = NSScreen.screens.first { $0.frame.intersects(context.caretRect) } ?? NSScreen.main
        guard let screen else { return }
        screenFrame = screen.visibleFrame
        quiet = context.documentSelection.length == 0 &&
            context.trailingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (context.caretQuality == .exact || context.caretQuality == .derived)
        let input = ExpressionAssistInputPanel(contentRect: .zero,
            styleMask: [.borderless], backing: .buffered, defer: true)
        configure(input)
        input.delegate = self
        input.title = String(localized: "Expression assistance", table: "Learning")
        let view = ExpressionAssistQueryView(frame: .zero)
        view.delegate = self
        view.font = font
        let inputColor = quiet ? NSColor.labelColor.withAlphaComponent(0.82) : NSColor.labelColor
        view.typingAttributes = [.font: font, .foregroundColor: inputColor]
        view.textColor = inputColor
        view.insertionPointColor = .controlAccentColor
        view.drawsBackground = false
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.string = initialQuery
        view.setAccessibilityIdentifier("lingrove.expression-assist.query")
        view.setAccessibilityLabel(String(localized: "Describe an expression or concept", table: "Learning"))
        view.onCommand = { [weak self] key in self?.handle(key) ?? false }
        view.onSelectIndex = { [weak self] index in self?.handleIndexSelection(index) ?? false }
        view.onCompositionChange = { [weak self] in self?.queryChanged() }
        let content = ExpressionAssistInputBackground()
        // A long description scrolls inside the temporary surface instead of covering the screen.
        // The NSTextView remains the input client, preserving native selection and IME ownership.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = view
        content.addSubview(scroll)
        queryScroll = scroll
        input.contentView = content
        queryView = view
        inputPanel = input
        request = nil
        result = nil
        failedText = ""
        message = nil
        loading = false
        lastQuery = initialQuery
        lastComposing = false
        observeLearningTools()
        guard layoutInput() else { hide(restoringHost: false); return }
        // Normal activation is required for reliable keyboard/IME delivery. It brings the app's
        // main and key windows forward, so give this input both roles BEFORE requesting activation.
        // Activating first would promote a previously opened Settings/Notebook window as well.
        input.initialFirstResponder = view
        input.makeFirstResponder(view)
        input.makeKeyAndOrderFront(nil)
        input.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<15 {
            guard inputPanel === input, !Task.isCancelled else { return }
            if hasKeyFocus && input.isMainWindow && input.firstResponder === view { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard inputPanel === input else { return }
        LingroveLogger.learning.info("Expression keyboard ownership", metadata: [
            "app_active": .stringConvertible(NSApp.isActive),
            "is_key": .stringConvertible(input.isKeyWindow),
            "is_main": .stringConvertible(input.isMainWindow),
            "input_is_first_responder": .stringConvertible(input.firstResponder === view),
            "frontmost_is_input_owner": .stringConvertible(
                NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        ])
        guard hasKeyFocus, input.isMainWindow, input.firstResponder === view, !Task.isCancelled else {
            hide(restoringHost: true)
            return
        }
        view.setSelectedRange(NSRange(location: initialQuery.utf16.count, length: 0))
        installMouseMonitors()
        showResults()
    }

    func update(result: ExpressionAssistResult?, message: String?, loading: Bool) {
        update(result: result, message: message, loading: loading, request: nil)
    }

    func update(result: ExpressionAssistResult?, message: String?, loading: Bool, request: ExpressionAssistRequest?) {
        if let request { self.request = request }
        guard self.result != result || self.message != message || self.loading != loading else { return }
        self.result = result
        self.message = message
        self.loading = loading
        selected = 0
        showResults()
    }

    func hide(restoringHost: Bool) {
        let host = context.flatMap { NSRunningApplication(processIdentifier: $0.processIdentifier) }
        let returnHost = restoringHost && ExpressionAssistFocusPolicy.shouldRestoreHost(
            frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            host: context?.processIdentifier ?? -1, inputOwner: ProcessInfo.processInfo.processIdentifier,
            inputOwnsKeyboard: hasKeyFocus)
        closing = true
        layoutTask?.cancel()
        layoutTask = nil
        toolSubscriptions.removeAll()
        if let localMouse { NSEvent.removeMonitor(localMouse); self.localMouse = nil }
        if let globalMouse { NSEvent.removeMonitor(globalMouse); self.globalMouse = nil }
        inputPanel?.orderOut(nil)
        candidatePanel?.orderOut(nil)
        inputPanel?.delegate = nil
        inputPanel?.contentView = nil
        queryView = nil
        queryScroll = nil
        inputPanel = nil
        candidatePanel = nil
        context = nil
        request = nil
        result = nil
        failedText = ""
        lastQuery = nil
        lastComposing = false
        renderedCandidates = nil
        // Return activation only for explicit acceptance/cancellation while we still own input.
        // An outside click or app switch belongs to the user and must never be undone here.
        if returnHost, let host, !host.isTerminated {
            NSApp.yieldActivation(to: host)
            host.activate(options: [])
        }
    }

    func textDidChange(_ notification: Notification) { queryChanged() }

    /// A failed/uncertain write gets a copy-only, non-key recovery window. It never reopens input
    /// or repeats an editor mutation, and it is not shown over a different frontmost application.
    func showFailure(context: FocusedInputSnapshot, text: String, message: String) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processIdentifier,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(context.caretRect) }) else { return }
        hide(restoringHost: false)
        failedText = text
        let width = Metrics.panelWidth(screen: screen.visibleFrame)
        let inset = Metrics.contentInset + 2
        let textWidth = width - inset * 2
        // Auto Layout sizes the window from its content, so a long message or candidate wraps and
        // grows the panel instead of overlapping the fixed rows the first version used.
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = textWidth
        let candidate = NSTextField(wrappingLabelWithString: text)
        candidate.font = .systemFont(ofSize: 14, weight: .medium)
        candidate.isSelectable = true
        candidate.preferredMaxLayoutWidth = textWidth
        let copy = NSButton(title: String(localized: "Copy"), target: self, action: #selector(copyFailure))
        copy.bezelStyle = .rounded
        // The panel never becomes key, so Return cannot fire it; the key equivalent still gives
        // Copy the system default-button appearance, marking it as the recommended action.
        copy.keyEquivalent = "\r"
        failureCopyButton = copy
        let close = NSButton(title: String(localized: "Close", table: "Learning"), target: self, action: #selector(closeFailure))
        close.bezelStyle = .rounded
        let buttons = NSStackView(views: [close, copy])
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.failureSpacing
        let stack = NSStackView(views: [label, candidate, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.failureSpacing
        stack.setCustomSpacing(Metrics.failureSpacing + 4, after: candidate)
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = ExpressionAssistGlassView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width)
        ])
        content.layoutSubtreeIfNeeded()
        let size = CGSize(width: width, height: ceil(stack.fittingSize.height))
        content.frame = CGRect(origin: .zero, size: size)
        guard let frame = LearningSentencePanelLayout.frame(caretRect: context.caretRect, contentSize: size,
            visibleFrame: screen.visibleFrame, reservedFrame: nil) else { return }
        let panel = ExpressionAssistResultPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        configure(panel)
        panel.contentView = content
        panel.hasShadow = true
        candidatePanel = panel
        panel.orderFrontRegardless()
        installMouseMonitors()
    }

    /// Copy confirms in place, then closes shortly after so the user sees the action took effect.
    /// The panel identity check avoids closing a newer window opened during the delay.
    @objc private func copyFailure() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(failedText, forType: .string)
        failureCopyButton?.title = String(localized: "Copied", table: "Learning") + " ✓"
        failureCopyButton?.isEnabled = false
        let panel = candidatePanel
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, self.candidatePanel === panel, self.inputPanel == nil else { return }
            self.hide(restoringHost: false)
        }
    }
    @objc private func closeFailure() { hide(restoringHost: false) }

    private func queryChanged() {
        guard let queryView, !closing else { return }
        let text = queryView.string
        let composing = queryView.hasMarkedText()
        let textChanged = text != lastQuery
        guard textChanged || composing != lastComposing else { return }
        let compositionChanged = composing != lastComposing
        lastQuery = text
        lastComposing = composing
        LingroveLogger.learning.debug("Expression input editing state", metadata: [
            "characters": .stringConvertible(text.count),
            "composing": .stringConvertible(composing)
        ])
        // Cancel stale generation immediately; merge only visual measurement. Native IME callbacks
        // and textDidChange can describe the same edit, and must not repeatedly force TextKit layout
        // while it is still processing that edit. The existing 450ms request debounce is unchanged.
        onQueryChanged?(text, composing)
        if compositionChanged { showResults() }
        if textChanged { scheduleInputLayout() }
    }

    private func scheduleInputLayout() {
        guard layoutTask == nil else { return }
        layoutTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.layoutTask = nil
            guard !self.closing else { return }
            guard self.layoutInput() else { self.onDismissed?(); return }
            self.showResults()
        }
    }

    private func handle(_ key: UInt16) -> Bool {
        guard queryView?.hasMarkedText() == false else { return false }
        let candidates = candidatePanel?.isVisible == true ? result?.candidates ?? [] : []
        switch key {
        case 53: onCancel?(); return true
        case 36, 76:
            if candidates.indices.contains(selected) { onAccept?(candidates[selected]) } else { onSubmit?() }
            return true
        case 48:
            guard candidates.indices.contains(selected) else { return false }
            onAccept?(candidates[selected]); return true
        case 125, 126:
            guard !candidates.isEmpty else { return false }
            selected = (selected + (key == 125 ? 1 : -1) + candidates.count) % candidates.count
            showResults()
            return true
        default: return false
        }
    }

    private func handleIndexSelection(_ index: Int) -> Bool {
        guard queryView?.hasMarkedText() == false,
              candidatePanel?.isVisible == true,
              let candidates = result?.candidates,
              candidates.indices.contains(index) else { return false }
        onAccept?(candidates[index])
        return true
    }

    @discardableResult
    private func layoutInput() -> Bool {
        guard let query = queryView, let context else { return false }
        inputLayoutPasses += 1
        let fieldRight = context.elementFrameRect?.maxX ?? screenFrame.maxX
        let available = min(fieldRight, screenFrame.maxX) - context.caretRect.minX - 8
        if available < Metrics.minInlineRoom { quiet = false }
        let maxWidth = Metrics.panelWidth(screen: screenFrame)
        let width = min(maxWidth, max(Metrics.minInputWidth, quiet ? available : maxWidth))
        let padding: CGFloat = quiet ? 0 : Metrics.inputPadding
        let containerSize = CGSize(width: width - padding * 2, height: .greatestFiniteMagnitude)
        if query.textContainer?.containerSize != containerSize { query.textContainer?.containerSize = containerSize }
        query.layoutManager?.ensureLayout(for: query.textContainer ?? NSTextContainer())
        let used = query.textContainer.flatMap { query.layoutManager?.usedRect(for: $0) } ?? .zero
        // Keep quiet input anchored at the caret baseline even when a description wraps onto a
        // second line; jumping to a framed box below the caret mid-sentence breaks typing flow.
        let wrapsMultiLine = quiet && used.height > lineHeight * 1.45
        let textHeight = max(lineHeight, used.height) + 2
        let height = min(textHeight, max(Metrics.minInputHeight, min(Metrics.maxInputHeight, screenFrame.height / 3))) + padding * 2
        let scrollFrame = CGRect(x: padding, y: padding, width: width - padding * 2, height: height - padding * 2)
        let queryFrame = CGRect(x: 0, y: 0, width: width - padding * 2, height: textHeight)
        guard let frame = ExpressionAssistLayout.input(anchor: .init(caret: context.caretRect,
            hostBaseline: hostBaseline, nativeBaseline: nativeBaseline), size: CGSize(width: width, height: height),
            screen: screenFrame, inline: quiet)
        else { return false }
        // Leave the user's literal trigger visible and start after it. Quiet input is entirely
        // transparent on the first line, with a subtle IME-like preedit underline.
        return applyInputFrames(
            input: frame,
            scrollFrame: scrollFrame,
            queryFrame: queryFrame,
            activeUnderlineWidth: min(width, max(44, ceil(used.width) + 6)),
            wrapsMultiLine: wrapsMultiLine
        )
    }

    /// Measurement above uses TextKit once. Applying it must not invalidate unchanged containers
    /// or flush a window redraw for every character; native text drawing already invalidates glyphs.
    private func applyInputFrames(
        input: CGRect,
        scrollFrame: CGRect,
        queryFrame: CGRect,
        activeUnderlineWidth: CGFloat,
        wrapsMultiLine: Bool
    ) -> Bool {
        guard let panel = inputPanel, let query = queryView, let scroll = queryScroll,
              let background = panel.contentView as? ExpressionAssistInputBackground else { return false }
        let sizeChanged = scroll.frame != scrollFrame || query.frame != queryFrame
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        if query.frame != queryFrame { query.frame = queryFrame }
        if sizeChanged { query.scrollRangeToVisible(query.selectedRange()) }
        if background.updateStyle(quiet: quiet, wrapsMultiLine: wrapsMultiLine, underlineWidth: activeUnderlineWidth) {
            background.needsDisplay = true
        }
        if panel.hasShadow == quiet { panel.hasShadow = !quiet }
        if panel.frame != input { panel.setFrame(input, display: false) }
        return true
    }

    private func showResults() {
        guard let input = inputPanel, isVisible else { return }
        let candidates = result?.candidates ?? []
        let state = currentCandidateState(candidates: candidates)
        guard needsCandidateRebuild(state) else { return }
        candidateBuilds += 1
        // Do not flash an empty footer bar while the user is still typing during the 450ms
        // debounce window. The candidate card appears only once work starts or results arrive.
        let hasVisibleContent = loading || message != nil || !candidates.isEmpty
        guard hasVisibleContent else {
            candidatePanel?.orderOut(nil)
            return
        }
        let content = ExpressionAssistFlippedView()
        let width = Metrics.panelWidth(screen: screenFrame)
        var offset: CGFloat = Metrics.contentInset
        // A clarification arrives *with* a result (possibly alongside candidates); an error or
        // cancellation arrives without one. Rendering them differently tells the user whether to
        // keep describing or to retry.
        if loading && candidates.isEmpty {
            offset += addStatus(to: content, kind: .loading,
                text: String(localized: "Finding an expression…", table: "Learning"), y: offset, width: width)
        } else if let message, result != nil {
            offset += addStatus(to: content, kind: .clarification, text: message, y: offset, width: width)
        } else if let message {
            offset += addStatus(to: content, kind: .failure, text: message, y: offset, width: width)
        }
        for index in candidates.indices {
            let candidate = candidates[index]
            let row = ExpressionAssistCandidateRow(
                candidate: candidate,
                index: index,
                selected: index == selected,
                expanded: true,
                isSpeaking: state.speakingIndex == index,
                onSpeak: speech == nil ? nil : { [weak self] in self?.toggleSpeech(for: candidate, index: index) },
                isSaved: state.savedIndices.contains(index),
                isSaving: state.savingIndices.contains(index),
                onToggleFavorite: vocabulary == nil ? nil : { [weak self] in self?.toggleFavorite(for: candidate) }
            )
            row.tag = index
            row.target = self
            row.action = #selector(selectCandidate(_:))
            let rowWidth = width - Metrics.rowInset * 2
            let height = row.height(for: rowWidth)
            row.frame = CGRect(x: Metrics.rowInset, y: offset, width: rowWidth, height: height)
            content.addSubview(row)
            offset += height + Metrics.rowSpacing
        }
        offset += addFooter(to: content, candidateCount: candidates.count, y: offset, width: width)
        content.frame = CGRect(x: 0, y: 0, width: width, height: offset)
        // Bounded model output can still be taller than a small screen. Keep every choice
        // reachable in a native scroll view rather than silently losing the entire result panel.
        let room = max(input.frame.minY - screenFrame.minY, screenFrame.maxY - input.frame.maxY) - 8
        let height = min(content.frame.height, Metrics.maxCandidateHeight, room)
        guard height > Metrics.footerHeight, let frame = ExpressionAssistLayout.candidates(input: input.frame,
            size: CGSize(width: width, height: height), screen: screenFrame) else {
            // Reusing the window must never leave an old choice visible when the new state cannot
            // be laid out: its button index would now refer to a different model result.
            candidatePanel?.orderOut(nil)
            renderedCandidates = nil
            return
        }
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: frame.size))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = content.frame.height > height
        scroll.autohidesScrollers = true
        scroll.documentView = content
        scroll.autoresizingMask = [.width, .height]
        let glass = ExpressionAssistGlassView(frame: CGRect(origin: .zero, size: frame.size))
        glass.addSubview(scroll)
        let panel = candidatePanel ?? ExpressionAssistResultPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        configure(panel)
        panel.hasShadow = true
        panel.contentView = glass
        panel.setFrame(frame, display: true)
        candidatePanel = panel
        panel.orderFrontRegardless()
    }

    /// Visibility and content are independent: native composition hides a retained result window,
    /// while confirmation can restore that same view. Only a different rendering receipt rebuilds.
    private func needsCandidateRebuild(_ state: CandidateState) -> Bool {
        if queryView?.hasMarkedText() == true {
            if candidatePanel?.isVisible == true { candidatePanel?.orderOut(nil) }
            return false
        }
        if state == renderedCandidates {
            let hasVisibleContent = state.loading || state.message != nil || !(state.result?.candidates.isEmpty ?? true)
            if hasVisibleContent, positionCandidates(), candidatePanel?.isVisible == false {
                candidatePanel?.orderFrontRegardless()
            }
            return false
        }
        renderedCandidates = state
        return true
    }

    private func positionCandidates() -> Bool {
        guard let input = inputPanel, let panel = candidatePanel,
              let frame = ExpressionAssistLayout.candidates(input: input.frame, size: panel.frame.size, screen: screenFrame) else {
            candidatePanel?.orderOut(nil)
            renderedCandidates = nil
            return false
        }
        if frame != panel.frame { panel.setFrame(frame, display: false) }
        return true
    }

    // MARK: Speech & Vocabulary Integration

    private func observeLearningTools() {
        toolSubscriptions.removeAll()
        if let speech {
            speech.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.showResults() }
                .store(in: &toolSubscriptions)
        }
        if let vocabulary {
            vocabulary.loadIfNeeded()
            vocabulary.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.showResults() }
                .store(in: &toolSubscriptions)
        }
    }

    private func currentCandidateState(candidates: [ExpressionAssistCandidate]) -> CandidateState {
        var speakingIndex: Int?
        var savedIndices = Set<Int>()
        var savingIndices = Set<Int>()
        if speech != nil || vocabulary != nil {
            for index in candidates.indices {
                let candidate = candidates[index]
                if let speech {
                    let target = speechTarget(for: index)
                    if speech.isPlaying(target) || speech.isPreparing(target) {
                        speakingIndex = index
                    }
                }
                if let vocabulary, let itemCapture = capture(for: candidate) {
                    if vocabulary.contains(itemCapture) { savedIndices.insert(index) }
                    if vocabulary.isPending(itemCapture) { savingIndices.insert(index) }
                }
            }
        }
        return CandidateState(
            result: result,
            message: message,
            loading: loading,
            selected: selected,
            quiet: quiet,
            speakingIndex: speakingIndex,
            savedIndices: savedIndices,
            savingIndices: savingIndices
        )
    }

    private func speechTarget(for index: Int) -> SpeechTarget {
        SpeechTarget(ownerID: sessionID, itemID: "expression.candidate.\(index)")
    }

    private func toggleSpeech(for candidate: ExpressionAssistCandidate, index: Int) {
        guard let speech else { return }
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let language = request.flatMap { LearningLanguage(rawValue: $0.targetLanguage) }
        speech.toggle(SpeechRequest(target: speechTarget(for: index), text: text, language: language))
    }

    private func toggleFavorite(for candidate: ExpressionAssistCandidate) {
        guard let vocabulary, let itemCapture = capture(for: candidate) else { return }
        Task { @MainActor in
            if vocabulary.contains(itemCapture) {
                await vocabulary.remove(itemCapture)
            } else {
                await vocabulary.save(itemCapture)
            }
        }
    }

    private func capture(for candidate: ExpressionAssistCandidate) -> VocabularyCapture? {
        let effectiveRequest = request ?? ExpressionAssistRequest(
            query: lastQuery ?? "",
            leftContext: context?.precedingText ?? "",
            rightContext: context?.trailingText ?? "",
            selectedText: "",
            targetLanguage: LearningLanguage.english.rawValue,
            explanationLanguage: LearningLanguage.chinese.rawValue
        )
        return VocabularyCaptureFactory.expressionAssist(
            candidate: candidate,
            request: effectiveRequest,
            appBundleIdentifier: context?.bundleIdentifier
        )
    }

    private enum StatusKind { case loading, clarification, failure }

    /// One status line: spinner, question or warning glyph, then wrapped text. Returns its height.
    private func addStatus(to content: NSView, kind: StatusKind, text: String, y top: CGFloat, width: CGFloat) -> CGFloat {
        let inset = Metrics.contentInset
        let iconSize = Metrics.statusIconSize
        let textX = inset + iconSize + 6
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = kind == .loading ? .secondaryLabelColor : .labelColor
        var detail: NSTextField?
        if kind == .clarification {
            let hint = NSTextField(wrappingLabelWithString:
                String(localized: "Add more detail to your description.", table: "Learning"))
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            detail = hint
        }
        let textWidth = width - textX - inset
        let labelHeight = measure(label, width: textWidth)
        label.frame = CGRect(x: textX, y: top + 4, width: textWidth, height: labelHeight)
        content.addSubview(label)
        var height = labelHeight + 8
        if let detail {
            let detailHeight = measure(detail, width: textWidth)
            detail.frame = CGRect(x: textX, y: label.frame.maxY + 2, width: textWidth, height: detailHeight)
            content.addSubview(detail)
            height += detailHeight + 2
        }
        let iconFrame = CGRect(x: inset, y: top + 5, width: iconSize, height: iconSize)
        switch kind {
        case .loading:
            let spinner = NSProgressIndicator(frame: iconFrame)
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            content.addSubview(spinner)
        case .clarification, .failure:
            let symbol = kind == .clarification ? "questionmark.circle" : "exclamationmark.triangle"
            let icon = NSImageView(frame: iconFrame)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = kind == .clarification ? .controlAccentColor : .systemOrange
            icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            content.addSubview(icon)
        }
        return height
    }

    /// Keyboard hint bar at the bottom of the candidate card. The hint text depends on what Return
    /// does right now (search vs insert) and whether arrows have multiple candidates to move between.
    private func addFooter(to content: NSView, candidateCount: Int, y top: CGFloat, width: CGFloat) -> CGFloat {
        let inset = Metrics.contentInset
        var currentTop = top
        if candidateCount > 0 {
            let divider = NSView(frame: CGRect(x: inset, y: currentTop + 2, width: width - inset * 2, height: 0.5))
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
            content.addSubview(divider)
            currentTop += 5
        }
        var keys: [(String, String)] = []
        if candidateCount > 1 { keys.append(("↑↓", String(localized: "Select", table: "Learning"))) }
        keys.append(("↵", candidateCount > 0 ? String(localized: "Insert", table: "Learning")
            : String(localized: "Search", table: "Learning")))
        if candidateCount > 0 { keys.append(("⇥", String(localized: "Insert", table: "Learning"))) }
        keys.append(("esc", String(localized: "Cancel", table: "Learning")))
        let hints = NSTextField(labelWithAttributedString: Self.keyHints(keys))
        hints.lineBreakMode = .byTruncatingTail
        hints.setAccessibilityLabel(keys.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
        let hintsHeight = ceil(hints.intrinsicContentSize.height)
        hints.frame = CGRect(x: inset, y: currentTop + (Metrics.footerHeight - hintsHeight) / 2,
            width: max(0, width - inset * 2), height: hintsHeight)
        content.addSubview(hints)
        return (currentTop - top) + Metrics.footerHeight + 2
    }

    /// Keys render emphasized, their actions muted, so the eye scans keys first.
    private static func keyHints(_ keys: [(String, String)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let key: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor]
        let action: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor]
        for (index, pair) in keys.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "   ", attributes: action)) }
            result.append(NSAttributedString(string: pair.0, attributes: key))
            result.append(NSAttributedString(string: " " + pair.1, attributes: action))
        }
        return result
    }

    private func measure(_ field: NSTextField, width: CGFloat) -> CGFloat {
        ceil(field.attributedStringValue.boundingRect(with: CGSize(width: width, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
    }

    @objc private func selectCandidate(_ sender: NSButton) {
        guard let candidates = result?.candidates, candidates.indices.contains(sender.tag) else { return }
        onAccept?(candidates[sender.tag])
    }

    private func configure(_ panel: NSPanel) {
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !closing else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, self.isVisible, !self.hasKeyFocus, !self.closing else { return }
            self.onDismissed?()
        }
    }

    private func installMouseMonitors() {
        localMouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.inputPanel && event.window !== self.candidatePanel,
               self.queryView?.hasMarkedText() != true { self.onDismissed?() }
            return event
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.queryView?.hasMarkedText() != true else { return }
            let point = LearningWindowInteraction.screenPoint(for: event)
            let inside = LearningWindowInteraction.contains(point, roots: [self.inputPanel, self.candidatePanel],
                hitWindowNumber: NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0))
            if !inside { self.onDismissed?() }
        }
    }
}

/// The temporary editor owns both main and key roles during its explicit activation round trip.
/// A key-only panel would leave Settings as the main window, which activation also brings forward.
private final class ExpressionAssistInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ExpressionAssistResultPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ExpressionAssistFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Adaptive frosted-glass backdrop matching `LearningCardChrome` for the AppKit candidate and
/// failure panels, keeping text legible over multi-line editors without heavy opaque chrome.
private final class ExpressionAssistGlassView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = ExpressionAssistLayout.Metrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.75
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
    }

    required init?(coder: NSCoder) { nil }
}

/// Renders either the quiet inline preedit anchor (a subtle accent underline on a single line, or
/// a soft pill when wrapping) or a frosted-glass input card when invoked mid-sentence.
private final class ExpressionAssistInputBackground: NSView {
    private(set) var quiet = true
    private var wrapsMultiLine = false
    private var underlineWidth: CGFloat = 60
    private let effectView = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effectView.material = .popover
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = ExpressionAssistLayout.Metrics.cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.isHidden = true
        addSubview(effectView, positioned: .below, relativeTo: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        effectView.frame = bounds
    }

    func updateStyle(quiet: Bool, wrapsMultiLine: Bool, underlineWidth: CGFloat) -> Bool {
        let changed = self.quiet != quiet || self.wrapsMultiLine != wrapsMultiLine ||
            abs(self.underlineWidth - underlineWidth) > 1
        self.quiet = quiet
        self.wrapsMultiLine = wrapsMultiLine
        self.underlineWidth = underlineWidth
        effectView.isHidden = quiet && !wrapsMultiLine
        return changed
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = ExpressionAssistLayout.Metrics.cornerRadius
        if !quiet || wrapsMultiLine {
            NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            border.lineWidth = 0.75
            border.stroke()
        } else {
            // Draw a delicate IME-like preedit underline along the active inline slot so the user
            // immediately distinguishes expression input from passive autocomplete ghost text.
            let lineWidth = min(bounds.width, max(36, underlineWidth))
            let underlineRect = NSRect(x: 0, y: 0.5, width: lineWidth, height: 1.5)
            NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: underlineRect, xRadius: 0.75, yRadius: 0.75).fill()
        }
    }
}

/// Native editing owns composition and undo. Commands are intercepted only outside marked text;
/// the global event tap must pass these keys through to this text input client unchanged.
private final class ExpressionAssistQueryView: NSTextView {
    var onCommand: ((UInt16) -> Bool)?
    var onSelectIndex: ((Int) -> Bool)?
    var onCompositionChange: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !hasMarkedText() {
            if modifiers.isEmpty, onCommand?(event.keyCode) == true { return }
            if modifiers == [.command],
               let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars), (1...9).contains(digit),
               onSelectIndex?(digit - 1) == true {
                return
            }
        }
        super.keyDown(with: event)
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        // NSTextView does not promise textDidChange for every preedit update. Notify explicitly so
        // a pending debounce cannot generate or accept the old committed query during composition.
        onCompositionChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let text = String(localized: "Describe an expression or concept…", table: "Learning")
        // Render the placeholder in tertiary color so an empty inline slot never looks like an
        // already generated autocomplete continuation.
        (text as NSString).draw(at: .zero, withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.tertiaryLabelColor])
    }
}
