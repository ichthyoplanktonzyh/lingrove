import AppKit
import Combine
import Foundation
import Logging

/// App-lifetime reading session. It borrows the existing translation/lexicon services
/// and card presenter, while owning cancellation and the optional selection affordance. A reading
/// receipt has no replacement capability, so no path from this type can write into another app.
@MainActor
final class LearningReadingCoordinator {
    private let service: any LearningSentenceGenerating
    private let reader: any LearningReadingSelecting
    private let panel: any LearningSentencePresenting
    private let icon: any LearningSelectionAffordancePresenting
    private let recognizer: (any LearningUnitRecognizing)?
    private let frontmostBundle: () -> String?
    private let availability: () -> Bool
    private let sourceAvailability: (LearningReadingSource) -> Bool
    private let beforePresent: () -> Void
    private let observesSystemEvents: Bool
    private var subscriptions = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private var work: Task<Void, Never>?
    private var unitWork: Task<Void, Never>?
    private var affordanceWork: Task<Void, Never>?
    private var revision = UUID()
    private var affordanceRevision = UUID()
    private var requestBundle: String?
    private var requiresShortcutPermission = false
    private var requestSource = LearningReadingSource.selection
    private var document: Document?
    private var pendingSelection: LearningReadingSelection?
    private var preparingSelection: LearningReadingSelection?
    private var running = false
    private var lastPointerDown: CGPoint?
    private var pointerDownBundle: String?
    /// A native lookup drag/click belongs to learning UI through mouse-up, even if released outside.
    private var pointerDownInsideLearningUI = false
    var isActive: Bool { document != nil || pendingSelection != nil || work != nil || panel.isVisible || affordanceWork != nil }

    /// One immutable receipt with its evolving view state. Keeping this value together prevents
    /// a late translation task from mixing languages or results from different selections.
    private struct Document {
        let capture: LearningReadingSelection
        let sourceLanguage: LearningLanguage?
        let targetLanguage: LearningLanguage
        let traceID: String
        var isLookup = false
        var translation = ""
        var units: [LearningUnit] = []
        var unitStage: LearningUnitStage = .pending
        var generating = true
        var translationIsComplete = false
        var expanded = false
        var message = ""
        var isError = false
    }

    init(
        service: any LearningSentenceGenerating, reader: any LearningReadingSelecting,
        panel: any LearningSentencePresenting, icon: (any LearningSelectionAffordancePresenting)? = nil,
        recognizer: (any LearningUnitRecognizing)? = nil,
        frontmostBundle: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        availability: @escaping () -> Bool = { true },
        sourceAvailability: @escaping (LearningReadingSource) -> Bool = { _ in true }, beforePresent: @escaping () -> Void = {},
        observesSystemEvents: Bool = true
    ) {
        self.service = service
        self.reader = reader
        self.panel = panel
        self.recognizer = recognizer
        self.frontmostBundle = frontmostBundle
        self.availability = availability
        self.sourceAvailability = sourceAvailability
        self.beforePresent = beforePresent
        self.observesSystemEvents = observesSystemEvents
        self.icon = icon ?? LearningSelectionIconPanel()
    }

    func start() {
        guard !running else { return }
        running = true
        reader.setInvalidationHandler { [weak self] in
            guard let self else { return }
            if let capture = self.document?.capture ?? self.preparingSelection ?? self.pendingSelection,
               !self.reader.isCurrent(capture) { self.dismiss() }
        }
        let settings = service.settings
        Publishers.MergeMany([
            settings.languageLearning.readingChanges,
            settings.$isGloballyEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseState.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]).sink { [weak self] in self?.dismiss() }.store(in: &subscriptions)
        settings.languageLearning.readingSourceChanges.sink { [weak self] source in
            guard let self else { return }
            // @Published emits before storage. Retire the edited source immediately, including
            // its pending selection icon, without touching another source's card or work.
            let hasRequest = self.work != nil || self.document != nil || self.panel.isVisible
            if (hasRequest && self.requestSource == source) || (source == .selection &&
                (self.pendingSelection != nil || self.affordanceWork != nil)) {
                self.dismiss()
            }
        }.store(in: &subscriptions)
        Publishers.Merge(
            settings.$perAppShortcutOverrides.dropFirst().map { _ in () },
            settings.languageLearning.$selectionIconEnabled.dropFirst().map { _ in () }
        )
        .sink { [weak self] in
            // @Published precedes storage. Reconcile the current app's effective policy on
            // the next turn; unrelated App edits and icon changes do not cancel a translation.
            Task { @MainActor [weak self] in self?.policiesChanged() }
        }.store(in: &subscriptions)
        settings.languageLearning.shortcutChanges.sink { [weak self] in
            Task { @MainActor [weak self] in self?.render() }
        }.store(in: &subscriptions)
        guard observesSystemEvents else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss(reason: "application-activated") } }
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.pointer(event) }
        }
        if let monitor { monitors.append(monitor) }
    }

    func stop() {
        reader.setInvalidationHandler(nil)
        running = false
        dismiss()
        subscriptions.removeAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }

    // swiftlint:disable cyclomatic_complexity
    /// The consuming tap does no AX reads. Unknown apps and conflicting bindings return the
    /// original event to the host; capture and generation run after that synchronous decision.
    /// Keep synchronous shortcut arbitration together so event consumption has one ordered exit path.
    func decide(_ event: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        let learning = service.settings.languageLearning
        let mask = ShortcutModifierMask(eventFlags: event.flags)
        if event.keyCode == 53, panel.dismissDetail() { return .consume }
        if event.keyCode == 53, panel.isVisible {
            dismiss()
            return .consume
        }
        if event.keyCode == 53, work != nil || reader.isSelectingRegion {
            dismiss()
            return .consume
        }
        if reader.isSelectingRegion { return .consume }
        let command = LearningReadingSource.allCases.first {
            let binding = learning.readingBinding($0)
            return binding.key == event.keyCode && binding.modifiers == mask && learning.readingEnabled($0)
        }
        let detailKey = event.keyCode == learning.keyCode && mask == learning.modifiers && document != nil
        if let command {
            guard enabled, sourceAvailability(command), let bundle = frontmostBundle(),
                service.settings.readingTranslationAllowed(command, in: bundle),
                service.settings.readingShortcutConflict(command, bundleIdentifier: bundle) == nil
            else { return .notHandled }
            guard !event.isAutorepeat else { return .consume }
            requestSelection(source: command)
            return .consume
        }
        if detailKey, enabled, service.settings.writingTranslationShortcutsAllowed(in: frontmostBundle()),
            service.settings.learningShortcutConflict(
                keyCode: learning.keyCode, modifiers: learning.modifiers,
                replacement: false, bundleIdentifier: frontmostBundle()) == nil {
            if !event.isAutorepeat {
                let id = revision
                Task { @MainActor [weak self] in
                    guard let self, self.revision == id else { return }
                    self.toggleDetails()
                }
            }
            return .consume
        }
        // All ordinary host input retires the receipt before AX can publish a changed selection.
        // Modifier transitions are not keyDown events, so holding Option does not dismiss a card.
        if isActive { dismiss() }
        return .notHandled
    }
    // swiftlint:enable cyclomatic_complexity

    func dismiss(reason: String = "explicit-or-invalidation") {
        if document != nil || panel.isVisible {
            LingroveLogger.learning.debug("Reading preview retired", metadata: ["stage": .string(reason)])
        }
        revision = UUID()
        pointerDownInsideLearningUI = false
        lastPointerDown = nil
        pointerDownBundle = nil
        work?.cancel()
        work = nil
        unitWork?.cancel()
        unitWork = nil
        affordanceWork?.cancel()
        affordanceWork = nil
        document = nil
        pendingSelection = nil
        preparingSelection = nil
        requestBundle = nil
        requiresShortcutPermission = false
        affordanceRevision = UUID()
        reader.forget()
        icon.hide()
        panel.hide()
    }

    func availabilityChanged() {
        if !availability() || !sourceAvailability(requestSource) { dismiss() }
    }

    private var enabled: Bool {
        let settings = service.settings
        return running && settings.isGloballyEnabled && !settings.isTemporarilyPaused
            && settings.languageLearning.translationEnabled && availability()
    }

    private func requestSelection(source: LearningReadingSource) {
        // Reuse the receipt captured at mouse-up, including its gesture. Recapturing here would
        // detach the old drag from its native selection identity, especially when the icon is off.
        if source == .selection, pendingSelection != nil || affordanceWork != nil {
            let id = revision
            let captureWork = affordanceWork
            let bundle = frontmostBundle()
            requestBundle = bundle
            requestSource = source
            requiresShortcutPermission = true
            work?.cancel()
            // decide() runs in the consuming key callback. Native receipt checks belong to the
            // scheduled task, just like fresh AX capture, so shortcut arbitration never blocks.
            work = Task { [weak self] in
                // Mouse-up deliberately waits for AX to settle. An immediate shortcut must join
                // that capture rather than cancel it and silently lose its bound gesture.
                await captureWork?.value
                guard !Task.isCancelled, let self, self.revision == id else { return }
                guard self.enabled, self.sourceAvailability(.selection), self.frontmostBundle() == bundle,
                      self.service.settings.readingTranslationAllowed(.selection, in: bundle)
                else { self.retireIfCurrent(id); return }
                if let pending = self.pendingSelection, pending.bundleIdentifier == bundle, self.reader.isCurrent(pending) {
                    self.activate(pending, fromShortcut: true)
                } else { self.requestFreshSelection(source: source) }
            }
            return
        }
        requestFreshSelection(source: source)
    }

    private func requestFreshSelection(source: LearningReadingSource) {
        dismiss()
        let id = revision
        let trace = RequestID.generate()
        requestSource = source
        let bundle = frontmostBundle()
        requestBundle = bundle
        requiresShortcutPermission = true
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.revision == id, self.document == nil {
                    self.work = nil; self.preparingSelection = nil; self.icon.hide()
                }
            }
            do {
                guard self.revision == id, self.enabled, self.sourceAvailability(source), self.frontmostBundle() == bundle,
                    self.service.settings.readingTranslationAllowed(source, in: bundle)
                else { return }
                let capture = try await LearningRequestTrace.$requestID.withValue(trace) {
                    let original = try await self.reader.capture(source: source)
                    try Task.checkCancellation()
                    guard self.revision == id, self.reader.isCurrent(original) else { throw CancellationError() }
                    self.preparingSelection = original
                    if source == .selection { self.icon.showProgress(anchor: original.anchor) }
                    return try await self.reader.enrich(original)
                }
                try Task.checkCancellation()
                guard self.revision == id, self.enabled, self.sourceAvailability(source), self.frontmostBundle() == bundle,
                    capture.bundleIdentifier == bundle, self.service.settings.readingTranslationAllowed(source, in: bundle)
                else { return }
                self.begin(capture, fromShortcut: true, traceID: trace)
            } catch is CancellationError { self.retireIfCurrent(id) } catch {
                guard self.revision == id, self.enabled, self.frontmostBundle() == bundle else { return }
                self.showCaptureError(error)
            }
        }
    }

    private func begin(_ capture: LearningReadingSelection, fromShortcut: Bool, traceID: String? = nil) {
        guard enabled, sourceAvailability(capture.source), service.settings.languageLearning.readingEnabled(capture.source),
            reader.isCurrent(capture)
        else {
            dismiss()
            return
        }
        requestBundle = capture.bundleIdentifier
        requestSource = capture.source
        requiresShortcutPermission = fromShortcut
        pendingSelection = nil
        preparingSelection = nil
        icon.hide()
        beforePresent()
        let target = service.settings.languageLearning.readingTargetLanguage
        let trace = traceID ?? capture.traceID ?? RequestID.generate()
        let resolution = LearningReadingLanguageResolver.resolve(text: capture.text,
            context: capture.context?.text, hint: capture.context?.languageHint ?? capture.languageHint)
        LingroveLogger.learning.debug("Reading source language resolved", metadata: [
            "request_id": .string(trace), "origin": .string(capture.source.rawValue),
            "source_language": .string(resolution.language?.rawValue ?? "und"),
            "language_evidence": .string(resolution.evidence.rawValue),
            "selection_utf16": .stringConvertible(capture.text.utf16.count),
            "context_utf16": .stringConvertible(capture.context?.text.utf16.count ?? 0),
            "context_method": .string(capture.context?.window.method.rawValue ?? "unavailable"),
            "context_complete": .stringConvertible(capture.context?.isComplete ?? false),
            "context_completeness": .string(capture.context?.completeness.rawValue ?? "none")
        ])
        // Source detection is advisory. Exact capture validation still gates the request, but
        // ambiguous short words and technical labels must reach both lookup and translation.
        let source = resolution.language
        document = Document(capture: capture, sourceLanguage: source, targetLanguage: target, traceID: trace)
        let decision = LearningReadingLookupPolicy.decision(capture, language: source)
        LearningReadingLog.emit(.routing, decision.reason.rawValue, details: [
            "reading_route": decision.capture == nil ? "translation" : "lookup",
            "origin": capture.source.rawValue
        ], requestID: trace)
        if beginLookup(capture, targetCapture: decision.capture, target: target) { return }
        guard source != target else {
            document = nil
            showCaptureError(
                LearningFailure.message(String(localized: "The text is already in the reading target language.", table: "Learning")))
            return
        }
        render()
        let id = revision
        LingroveLogger.learning.info(
            "Reading translation requested",
            metadata: [
                "request_id": .string(trace), "origin": .string(capture.source.rawValue),
                "bundle": .string(capture.bundleIdentifier), "target_bytes": .stringConvertible(capture.text.utf8.count)
            ])
        work = Task { [weak self] in
            guard let self else { return }
            await LearningRequestTrace.$requestID.withValue(trace) {
                do {
                    let translation = try await self.service.translateReadingSelection(
                        source: capture.text, sourceLanguage: source, targetLanguage: target, readingSource: capture.source,
                        onPartial: { [weak self] text in
                            guard let self, !Task.isCancelled,
                                  self.valid(id, capture, verifyCapture: self.document?.translation.isEmpty != false),
                                  self.document?.generating == true, self.document?.translationIsComplete == false else { return }
                            self.document?.translation = text
                            self.render()
                        })
                    try Task.checkCancellation()
                    guard self.valid(id, capture) else {
                        self.retireIfCurrent(id)
                        return
                    }
                    self.work = nil
                    self.document?.translation = translation
                    self.document?.translationIsComplete = true
                    self.document?.generating = false
                    self.render()
                    self.startUnits()
                } catch is CancellationError { self.retireIfCurrent(id) } catch {
                    guard self.valid(id, capture) else {
                        self.retireIfCurrent(id)
                        return
                    }
                    self.work = nil
                    self.document?.translation = ""
                    self.document?.generating = false
                    self.document?.isError = true
                    self.document?.message = error.localizedDescription
                    self.render()
                }
            }
        }
    }

    /// Lookup owns its two-stage model work in the shared card session. This coordinator
    /// retains only capture eligibility and supplies the same stale-receipt guard as translation.
    private func beginLookup(_ capture: LearningReadingSelection, targetCapture: VocabularyCapture?, target: LearningLanguage) -> Bool {
        guard let lookupPanel = panel as? any LearningLookupPresenting,
              let targetCapture else { return false }
        document?.isLookup = true
        document?.generating = false
        work = nil
        let id = revision
        lookupPanel.showLookup(.init(id: capture.id, capture: targetCapture, translationLanguage: target,
            anchor: capture.anchor, traceID: document?.traceID),
            validate: { [weak self] in
                guard let self else { return false }
                let current = self.valid(id, capture)
                if !current { self.retireIfCurrent(id) }
                return current
            }, dismiss: { [weak self] in self?.dismiss() })
        return true
    }

    private func valid(_ id: UUID, _ capture: LearningReadingSelection, verifyCapture: Bool = true) -> Bool {
        guard revision == id, enabled, sourceAvailability(capture.source),
              service.settings.languageLearning.readingEnabled(capture.source), shortcutPermissionValid else { return false }
        // AX is cross-process work. Verify the first visible prefix and final result in full;
        // intermediate display-only updates use session/policy/app identity. Existing AX
        // observers and key/mouse/workspace events retire a changed selection between those gates.
        return verifyCapture ? reader.isCurrent(capture) : frontmostBundle() == capture.bundleIdentifier
    }

    private var shortcutPermissionValid: Bool {
        !requiresShortcutPermission || service.settings.readingTranslationAllowed(requestSource, in: requestBundle)
    }

    private func policiesChanged() {
        guard shortcutPermissionValid else {
            dismiss()
            return
        }
        let bundle = pendingSelection?.bundleIdentifier ?? frontmostBundle()
        guard !service.settings.selectionIconAllowed(in: bundle) else { return }
        icon.hide()
        // A hidden receipt still serves an explicitly permitted shortcut. Turning off the icon
        // changes presentation, not the source evidence frozen at the preceding selection gesture.
        guard !service.settings.readingTranslationAllowed(.selection, in: bundle) else { return }
        affordanceRevision = UUID()
        affordanceWork?.cancel()
        affordanceWork = nil
        pendingSelection = nil
        icon.hide()
        if document == nil, work == nil { reader.forget() }
    }
    private func retireIfCurrent(_ id: UUID) { if revision == id { dismiss() } }

    private func toggleDetails() {
        guard let document, reader.isCurrent(document.capture) else {
            dismiss()
            return
        }
        if document.isLookup { (panel as? any LearningLookupPresenting)?.toggleLookupDetails(); return }
        self.document?.expanded.toggle()
        render()
    }

    private func startUnits() {
        unitWork?.cancel()
        guard let document, document.translationIsComplete, !document.translation.isEmpty, let recognizer else { return }
        let id = revision
        unitWork = Task { [weak self] in
            do {
                let units = try await recognizer.recognize(document.translation, language: document.targetLanguage)
                try Task.checkCancellation()
                guard let self, self.valid(id, document.capture) else { return }
                self.document?.units = units
                self.document?.unitStage = .ready
                self.render()
            } catch {
                guard !Task.isCancelled, let self, self.valid(id, document.capture) else { return }
                self.document?.unitStage = .failed
                self.render()
            }
        }
    }

    private func render() {
        guard let document, enabled, !document.isLookup else { return }
        guard !document.translation.isEmpty || !document.generating else { return }
        panel.show(
            .init(
                id: document.capture.id, source: document.capture.text, translation: document.translation,
                sourceLanguage: document.sourceLanguage, targetLanguage: document.targetLanguage,
                caret: document.capture.anchor, isExpanded: document.expanded, isGenerating: document.generating,
                message: document.message, previousTranslation: nil, shortcutLabel: service.settings.languageLearning.keyLabel,
                units: document.units, unitStage: document.unitStage, targetIsSelection: true, canReplace: false,
                isError: document.isError, readingSource: document.capture.source,
                isTranslating: !document.translationIsComplete && document.generating,
                vocabularyContext: document.capture.vocabularyContext,
                vocabularyAppBundleIdentifier: document.capture.bundleIdentifier), expand: { [weak self] in self?.toggleDetails() },
            dismiss: { [weak self] in self?.dismiss() },
            replace: nil)
        if !document.translation.isEmpty { service.recordDisplay(source: .translation, requestID: document.traceID) }
    }

    private func showCaptureError(_ error: Error) {
        beforePresent()
        work = nil
        preparingSelection = nil
        icon.hide()
        panel.show(
            .init(
                id: UUID(), source: "", translation: "", sourceLanguage: nil,
                targetLanguage: service.settings.languageLearning.readingTargetLanguage,
                caret: CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 18)),
                isExpanded: false, isGenerating: false, message: error.localizedDescription, previousTranslation: nil,
                shortcutLabel: service.settings.languageLearning.keyLabel, isError: true),
            expand: {}, dismiss: { [weak self] in self?.dismiss() }, replace: nil)
    }

    private func pointer(_ event: NSEvent) {
        let clicks = event.type == .leftMouseUp ? event.clickCount : 0
        handlePointerEvent(type: event.type, at: LearningWindowInteraction.screenPoint(for: event), clickCount: clicks)
    }

    /// The global monitor supplies an immutable event summary. Tests can exercise this routing
    /// without generating system input; only the panel performs Window Server hit testing.
    func handlePointerEvent(type: NSEvent.EventType, at point: CGPoint, clickCount: Int) {
        guard enabled, !reader.isSelectingRegion else { return }
        if type == .leftMouseDown {
            pointerDownInsideLearningUI = panel.containsGlobalInteraction(at: point)
            if pointerDownInsideLearningUI { lastPointerDown = nil; return }
            dismiss(reason: "external-pointer-down")
            lastPointerDown = point
            pointerDownBundle = frontmostBundle()
        } else if type == .rightMouseDown || type == .scrollWheel {
            guard !panel.containsGlobalInteraction(at: point) else { return }
            dismiss(reason: "external-pointer-or-scroll")
        } else if type == .leftMouseUp {
            handlePointerUp(at: point, clickCount: clickCount)
        }
    }

    /// An owned mouse-down keeps ownership until release, including a drag that ends outside.
    /// Only an external selection gesture may schedule the delayed passive translation icon.
    private func handlePointerUp(at point: CGPoint, clickCount: Int) {
        if pointerDownInsideLearningUI {
            pointerDownInsideLearningUI = false
            lastPointerDown = nil
            return
        }
        guard !panel.containsGlobalInteraction(at: point) else { lastPointerDown = nil; return }
        let start = lastPointerDown
        let sameApp = pointerDownBundle == frontmostBundle()
        let dragged = start.map { hypot($0.x - point.x, $0.y - point.y) > 3 } ?? false
        let completedAt = Date()
        lastPointerDown = nil
        pointerDownBundle = nil
        guard sourceAvailability(.selection), service.settings.languageLearning.selectionTranslationEnabled,
            dragged || clickCount >= 2,
            canCaptureSelection(in: frontmostBundle())
        else { return }
        let id = revision
        let iconID = affordanceRevision
        let bundle = frontmostBundle()
        affordanceWork = Task { [weak self] in
            defer {
                if let self, self.revision == id, self.affordanceRevision == iconID { self.affordanceWork = nil }
            }
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self, self.revision == id, self.affordanceRevision == iconID,
                    self.enabled, self.frontmostBundle() == bundle,
                    self.canCaptureSelection(in: bundle)
                else { return }
                var capture = try await self.reader.capture()
                try Task.checkCancellation()
                guard self.revision == id, self.affordanceRevision == iconID, self.reader.isCurrent(capture), self.enabled,
                    capture.bundleIdentifier == bundle,
                    self.canCaptureSelection(in: capture.bundleIdentifier)
                else { return }
                if let start, sameApp, dragged || clickCount == 2 {
                    capture.gesture = LearningReadingGesture(selectionID: capture.id, start: start, end: point,
                        kind: dragged ? .drag : .doubleClick, completedAt: completedAt)
                }
                self.pendingSelection = capture
                self.affordanceWork = nil
                guard self.service.settings.selectionIconAllowed(in: capture.bundleIdentifier) else { return }
                self.icon.show(anchor: capture.anchor) { [weak self, selectionID = capture.id] in
                    guard let self, let pending = self.pendingSelection, pending.id == selectionID else { return }
                    self.activate(pending)
                }
            } catch { /* Unsupported selections have no passive affordance and send no request. */  }
        }
    }

    private func canCaptureSelection(in bundle: String?) -> Bool {
        service.settings.selectionIconAllowed(in: bundle) || service.settings.readingTranslationAllowed(.selection, in: bundle)
    }

    /// The passive icon consumes its receipt once. Enrichment finishes before the first basic
    /// lookup/translation request; an OCR completion can never start a second model request.
    private func activate(_ capture: LearningReadingSelection, fromShortcut: Bool = false) {
        guard pendingSelection?.id == capture.id, enabled, reader.isCurrent(capture) else { return }
        pendingSelection = nil
        preparingSelection = capture
        icon.showProgress(anchor: capture.anchor)
        let id = revision
        let trace = capture.traceID ?? RequestID.generate()
        requestBundle = capture.bundleIdentifier
        requestSource = .selection
        requiresShortcutPermission = fromShortcut
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.revision == id, self.document == nil {
                    self.work = nil; self.preparingSelection = nil; self.icon.hide()
                }
            }
            do {
                let enriched = try await LearningRequestTrace.$requestID.withValue(trace) { try await self.reader.enrich(capture) }
                try Task.checkCancellation()
                guard self.revision == id, self.enabled, self.frontmostBundle() == capture.bundleIdentifier else { return }
                self.begin(enriched, fromShortcut: fromShortcut, traceID: trace)
            } catch is CancellationError { self.retireIfCurrent(id) } catch {
                guard self.revision == id, self.enabled, self.frontmostBundle() == capture.bundleIdentifier else { return }
                self.showCaptureError(error)
            }
        }
    }
}
