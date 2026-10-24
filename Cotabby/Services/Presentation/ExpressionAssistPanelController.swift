import AppKit
import Logging

/// Owns one key-capable input panel and a separate non-key candidate panel. Typing belongs to a
/// real NSTextView (including IME marked text), while candidate clicks never move the insertion
/// point. The input temporarily activates Lingrove to establish system keyboard/IME ownership;
/// its borderless appearance stays at the host caret. Hiding explicitly returns the original app
/// only if this input still owns focus. Neither window inserts temporary query text in the host.
@MainActor
final class ExpressionAssistPanelController: NSObject, ExpressionAssistPresenting, NSTextViewDelegate, NSWindowDelegate {
    var onQueryChanged: ((String, Bool) -> Void)?
    var onSubmit: (() -> Void)?
    var onAccept: ((ExpressionAssistCandidate) -> Void)?
    var onCancel: (() -> Void)?
    var onDismissed: (() -> Void)?
    private var inputPanel: ExpressionAssistInputPanel?
    private var candidatePanel: ExpressionAssistResultPanel?
    private var queryView: ExpressionAssistQueryView?
    private var queryScroll: NSScrollView?
    private var context: FocusedInputSnapshot?
    private var result: ExpressionAssistResult?
    private var message: String?
    private var loading = false
    private var selected = 0
    private var expanded = false
    private var quiet = true
    private var closing = false
    private var localMouse: Any?
    private var globalMouse: Any?
    private var font = NSFont.systemFont(ofSize: 14)
    private var screenFrame = CGRect.zero
    private var failedText = ""
    private var lastQuery: String?
    private var lastComposing = false
    private var layoutTask: Task<Void, Never>?
    private var renderedCandidates: CandidateState?
    private var lineHeight: CGFloat = 0
    private var hostBaseline: CGFloat = 0
    private var nativeBaseline: CGFloat = 0
    /// Content-free work counters let native regression tests enforce coalescing and view reuse.
    private(set) var inputLayoutPasses = 0
    private(set) var candidateBuilds = 0

    /// A window-lifetime rendering receipt, independent of query text. Composition changes only
    /// visibility; only different content or display mode rebuilds the candidate views.
    private struct CandidateState: Equatable {
        let result: ExpressionAssistResult?
        let message: String?
        let loading: Bool
        let selected: Int
        let expanded: Bool
        let quiet: Bool
    }
    var isVisible: Bool { inputPanel?.isVisible == true }
    var hasKeyFocus: Bool { isVisible && NSApp.isActive && inputPanel?.isKeyWindow == true }

    func show(context: FocusedInputSnapshot, trigger: String, initialQuery: String) async {
        hide(restoringHost: false)
        self.context = context
        closing = false
        expanded = false
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
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        view.textColor = .secondaryLabelColor
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
        result = nil
        failedText = ""
        message = nil
        loading = false
        lastQuery = initialQuery
        lastComposing = false
        guard layoutInput() else { hide(restoringHost: false); return }
        // isKeyWindow on an inactive nonactivating panel did not prove that WindowServer routed
        // real typing or the input method to it. Establish normal application activation instead,
        // then wait for the system acknowledgment before reporting this session as ready.
        input.initialFirstResponder = view
        input.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        input.makeKeyAndOrderFront(nil)
        for _ in 0..<15 {
            guard inputPanel === input, !Task.isCancelled else { return }
            if hasKeyFocus && input.firstResponder === view { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard inputPanel === input else { return }
        CotabbyLogger.learning.info("Expression keyboard ownership", metadata: [
            "app_active": .stringConvertible(NSApp.isActive),
            "is_key": .stringConvertible(input.isKeyWindow),
            "input_is_first_responder": .stringConvertible(input.firstResponder === view),
            "frontmost_is_input_owner": .stringConvertible(
                NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        ])
        guard hasKeyFocus, input.firstResponder === view, !Task.isCancelled else {
            hide(restoringHost: true)
            return
        }
        view.setSelectedRange(NSRange(location: initialQuery.utf16.count, length: 0))
        installMouseMonitors()
        showResults()
    }

    func update(result: ExpressionAssistResult?, message: String?, loading: Bool) {
        guard self.result != result || self.message != message || self.loading != loading else { return }
        self.result = result
        self.message = message
        self.loading = loading
        selected = 0
        expanded = false
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
        let width = min(380, screen.visibleFrame.width - 20)
        let content = ExpressionAssistFlippedView(frame: CGRect(x: 0, y: 0, width: width, height: 150))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.cornerRadius = 8
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.frame = CGRect(x: 10, y: 10, width: width - 20, height: 48)
        content.addSubview(label)
        let candidate = NSTextField(wrappingLabelWithString: text)
        candidate.isSelectable = true
        candidate.frame = CGRect(x: 10, y: 64, width: width - 20, height: 40)
        content.addSubview(candidate)
        let copy = NSButton(title: String(localized: "Copy"), target: self, action: #selector(copyFailure))
        copy.frame = CGRect(x: 10, y: 112, width: 80, height: 25)
        content.addSubview(copy)
        let close = NSButton(title: String(localized: "Close", table: "Learning"), target: self, action: #selector(closeFailure))
        close.frame = CGRect(x: 100, y: 112, width: 80, height: 25)
        content.addSubview(close)
        guard let frame = LearningSentencePanelLayout.frame(caretRect: context.caretRect, contentSize: content.frame.size,
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

    @objc private func copyFailure() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(failedText, forType: .string)
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
        CotabbyLogger.learning.debug("Expression input editing state", metadata: [
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
            expanded = true
            showResults()
            return true
        default: return false
        }
    }

    @discardableResult
    private func layoutInput() -> Bool {
        guard let query = queryView, let context else { return false }
        inputLayoutPasses += 1
        let fieldRight = context.elementFrameRect?.maxX ?? screenFrame.maxX
        let available = min(fieldRight, screenFrame.maxX) - context.caretRect.minX - 8
        if available < 140 { quiet = false }
        let width = min(380, screenFrame.width - 20, max(160, quiet ? available : 380))
        let padding: CGFloat = quiet ? 0 : 8
        let containerSize = CGSize(width: width - padding * 2, height: .greatestFiniteMagnitude)
        if query.textContainer?.containerSize != containerSize { query.textContainer?.containerSize = containerSize }
        query.layoutManager?.ensureLayout(for: query.textContainer ?? NSTextContainer())
        let used = query.textContainer.flatMap { query.layoutManager?.usedRect(for: $0) } ?? .zero
        if quiet && used.height > lineHeight * 1.5 { quiet = false; return layoutInput() }
        let textHeight = max(lineHeight, used.height) + 2
        let height = min(textHeight, max(50, min(180, screenFrame.height / 3))) + padding * 2
        let scrollFrame = CGRect(x: padding, y: padding, width: width - padding * 2, height: height - padding * 2)
        let queryFrame = CGRect(x: 0, y: 0, width: width - padding * 2, height: textHeight)
        guard let frame = ExpressionAssistLayout.input(anchor: .init(caret: context.caretRect,
            hostBaseline: hostBaseline, nativeBaseline: nativeBaseline), size: CGSize(width: width, height: height),
            screen: screenFrame, inline: quiet)
        else { return false }
        // Leave the user's literal trigger visible and start after it. Quiet input is entirely
        // transparent; guessing a host background to erase its marker would paint over real text.
        return applyInputFrames(input: frame, scrollFrame: scrollFrame, queryFrame: queryFrame)
    }

    /// Measurement above uses TextKit once. Applying it must not invalidate unchanged containers
    /// or flush a window redraw for every character; native text drawing already invalidates glyphs.
    private func applyInputFrames(input: CGRect, scrollFrame: CGRect, queryFrame: CGRect) -> Bool {
        guard let panel = inputPanel, let query = queryView, let scroll = queryScroll,
              let background = panel.contentView as? ExpressionAssistInputBackground else { return false }
        let sizeChanged = scroll.frame != scrollFrame || query.frame != queryFrame
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        if query.frame != queryFrame { query.frame = queryFrame }
        if sizeChanged { query.scrollRangeToVisible(query.selectedRange()) }
        if background.quiet != quiet { background.quiet = quiet; background.needsDisplay = true }
        if panel.hasShadow == quiet { panel.hasShadow = !quiet }
        if panel.frame != input { panel.setFrame(input, display: false) }
        return true
    }

    private func showResults() {
        guard let input = inputPanel, isVisible else { return }
        let state = CandidateState(result: result, message: message, loading: loading,
            selected: selected, expanded: expanded, quiet: quiet)
        guard needsCandidateRebuild(state) else { return }
        candidateBuilds += 1
        let candidates = result?.candidates ?? []
        let canExpand = candidates.count > 1 || candidates.contains { !$0.hint.isEmpty }
        let content = ExpressionAssistFlippedView()
        let width = min(380, screenFrame.width - 20)
        var offset: CGFloat = quiet && !expanded ? 0 : 8
        if !candidates.isEmpty {
            let indices = quiet && !expanded ? [selected] : Array(candidates.indices)
            for index in indices where candidates.indices.contains(index) {
                let row = ExpressionAssistCandidateRow(candidate: candidates[index], selected: index == selected,
                    expanded: !quiet || expanded)
                row.tag = index
                row.target = self
                row.action = #selector(selectCandidate(_:))
                let height = row.height(for: width - 12)
                row.frame = CGRect(x: 4, y: offset, width: width - 12, height: height)
                content.addSubview(row)
                offset += height + 3
            }
        } else if loading || message != nil {
            let label = NSTextField(wrappingLabelWithString: message ?? String(localized: "Finding an expression…", table: "Learning"))
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            let height = ceil(label.attributedStringValue.boundingRect(with: CGSize(width: width - 16, height: 1_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 8
            label.frame = CGRect(x: 8, y: offset, width: width - 16, height: height)
            content.addSubview(label)
            offset += height
        }
        if canExpand {
            let more = NSButton(title: expanded ? String(localized: "Fewer ↑", table: "Learning") :
                String(localized: "More ↓", table: "Learning"), target: self, action: #selector(toggleExpanded))
            more.isBordered = false
            more.font = .systemFont(ofSize: 11)
            more.frame = CGRect(x: 3, y: offset, width: 70, height: 24)
            content.addSubview(more)
        }
        let cancel = NSButton(title: String(localized: "Esc · Cancel", table: "Learning"), target: self, action: #selector(cancelPressed))
        cancel.isBordered = false
        cancel.font = .systemFont(ofSize: 11)
        cancel.frame = CGRect(x: canExpand ? 78 : 3, y: offset, width: 90, height: 24)
        content.addSubview(cancel)
        offset += 26
        content.frame = CGRect(x: 0, y: 0, width: width, height: offset)
        content.wantsLayer = true
        if !quiet || expanded {
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            content.layer?.cornerRadius = 8
            content.layer?.borderWidth = 0.5
            content.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        // Bounded model output can still be taller than a small screen. Keep every choice
        // reachable in a native scroll view rather than silently losing the entire result panel.
        let room = max(input.frame.minY - screenFrame.minY, screenFrame.maxY - input.frame.maxY) - 8
        let height = min(content.frame.height, 320, room)
        guard height > 24, let frame = ExpressionAssistLayout.candidates(input: input.frame,
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
        let panel = candidatePanel ?? ExpressionAssistResultPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        configure(panel)
        panel.hasShadow = !quiet || expanded
        panel.contentView = scroll
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
            if positionCandidates(), candidatePanel?.isVisible == false { candidatePanel?.orderFrontRegardless() }
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

    @objc private func selectCandidate(_ sender: NSButton) {
        guard let candidates = result?.candidates, candidates.indices.contains(sender.tag) else { return }
        onAccept?(candidates[sender.tag])
    }
    @objc private func toggleExpanded() { expanded.toggle(); showResults() }
    @objc private func cancelPressed() { onCancel?() }

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

/// A borderless input needs an explicit key-window override. Normal application activation gives
/// NSTextView the same keyboard/IME dispatch as a regular editor without adding visible chrome.
private final class ExpressionAssistInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ExpressionAssistResultPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ExpressionAssistFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ExpressionAssistInputBackground: NSView {
    var quiet = true
    override func draw(_ dirtyRect: NSRect) {
        if !quiet {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
        }
    }
}

/// Native editing owns composition and undo. Commands are intercepted only outside marked text;
/// the global event tap must pass these keys through to this text input client unchanged.
private final class ExpressionAssistQueryView: NSTextView {
    var onCommand: ((UInt16) -> Bool)?
    var onCompositionChange: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.shift), onCommand?(event.keyCode) == true { return }
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
        (text as NSString).draw(at: .zero, withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor])
    }
}
