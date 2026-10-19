import AppKit
import Combine
import Foundation
import Logging

/// App-lifetime reading session. It borrows the existing translation/alignment/lexicon services
/// and card presenter, while owning cancellation and the optional selection affordance. A reading
/// receipt has no replacement capability, so no path from this type can write into another app.
@MainActor
final class LearningReadingCoordinator {
    private let service: any LearningSentenceGenerating
    private let reader: any LearningReadingSelecting
    private let panel: any LearningSentencePresenting
    private let icon: LearningSelectionIconPanel
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
    private var analysisWork: Task<Void, Never>?
    private var analysisRevision = UUID()
    private var unitWork: Task<Void, Never>?
    private var affordanceWork: Task<Void, Never>?
    private var revision = UUID()
    private var affordanceRevision = UUID()
    private var requestBundle: String?
    private var requiresShortcutPermission = false
    private var requestSource = LearningReadingSource.selection
    private var document: Document?
    private var pendingSelection: LearningReadingSelection?
    private var running = false
    private var lastPointerDown: CGPoint?
    var isActive: Bool { document != nil || pendingSelection != nil || work != nil || panel.isVisible || affordanceWork != nil }

    /// One immutable receipt with its evolving view state. Keeping this value together prevents
    /// a late translation/alignment task from mixing languages or results from different selections.
    private struct Document {
        let capture: LearningReadingSelection
        let sourceLanguage: LearningLanguage
        let targetLanguage: LearningLanguage
        let traceID: String
        var translation = ""
        var chunks: [LearningMeaningChunk] = []
        var units: [LearningUnit] = []
        var unitStage: LearningUnitStage = .pending
        var generating = true
        var expanded = false
        var message = ""
        var isError = false
    }

    init(
        service: any LearningSentenceGenerating, reader: any LearningReadingSelecting,
        panel: any LearningSentencePresenting, recognizer: (any LearningUnitRecognizing)? = nil,
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
        icon = LearningSelectionIconPanel()
    }

    func start() {
        guard !running else { return }
        running = true
        reader.setInvalidationHandler { [weak self] in
            guard let self else { return }
            if let capture = self.document?.capture ?? self.pendingSelection, !self.reader.isCurrent(capture) { self.dismiss() }
        }
        let settings = service.settings
        Publishers.MergeMany([
            settings.languageLearning.readingChanges,
            settings.$isGloballyEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseState.dropFirst().map { _ in () }.eraseToAnyPublisher(),
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
        settings.languageLearning.analysisChanges.sink { [weak self] in
            self?.analysisWork?.cancel()
            self?.analysisRevision = UUID()
            Task { @MainActor [weak self] in self?.startAnalysis() }
        }.store(in: &subscriptions)
        settings.languageLearning.shortcutChanges.sink { [weak self] in
            Task { @MainActor [weak self] in self?.render() }
        }.store(in: &subscriptions)
        guard observesSystemEvents else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
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

    /// The consuming tap does no AX reads. Unknown apps and conflicting bindings return the
    /// original event to the host; capture and generation run after that synchronous decision.
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
                replacement: false, bundleIdentifier: frontmostBundle()) == nil
        {
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

    func dismiss() {
        revision = UUID()
        work?.cancel()
        work = nil
        analysisWork?.cancel()
        analysisWork = nil
        unitWork?.cancel()
        unitWork = nil
        affordanceWork?.cancel()
        affordanceWork = nil
        document = nil
        pendingSelection = nil
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
        dismiss()
        let id = revision
        let trace = RequestID.generate()
        requestSource = source
        let bundle = frontmostBundle()
        requestBundle = bundle
        requiresShortcutPermission = true
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == id, self.document == nil { self.work = nil } }
            do {
                guard self.revision == id, self.enabled, self.sourceAvailability(source), self.frontmostBundle() == bundle,
                    self.service.settings.readingTranslationAllowed(source, in: bundle)
                else { return }
                let capture = try await LearningRequestTrace.$requestID.withValue(trace) {
                    try await self.reader.capture(source: source)
                }
                try Task.checkCancellation()
                guard self.revision == id, self.enabled, self.sourceAvailability(source), self.frontmostBundle() == bundle,
                    capture.bundleIdentifier == bundle, self.service.settings.readingTranslationAllowed(source, in: bundle)
                else { return }
                self.begin(capture, fromShortcut: true, traceID: trace)
            } catch is CancellationError {} catch {
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
        icon.hide()
        beforePresent()
        let target = service.settings.languageLearning.readingTargetLanguage
        guard let source = capture.languageHint ?? LearningLanguage.detect(in: capture.text) else {
            showCaptureError(
                LearningFailure.message(
                    String(localized: "Could not identify the text language. Try a larger text region.", table: "Learning")))
            return
        }
        guard source != target else {
            showCaptureError(
                LearningFailure.message(String(localized: "The text is already in the reading target language.", table: "Learning")))
            return
        }
        let trace = traceID ?? RequestID.generate()
        document = Document(capture: capture, sourceLanguage: source, targetLanguage: target, traceID: trace)
        render()
        let id = revision
        CotabbyLogger.learning.info(
            "Reading translation requested",
            metadata: [
                "request_id": .string(trace), "origin": .string(capture.source.rawValue),
                "bundle": .string(capture.bundleIdentifier), "target_bytes": .stringConvertible(capture.text.utf8.count),
            ])
        work = Task { [weak self] in
            guard let self else { return }
            await LearningRequestTrace.$requestID.withValue(trace) {
                do {
                    let translation = try await self.service.translateReadingSelection(
                        source: capture.text, sourceLanguage: source, targetLanguage: target, readingSource: capture.source)
                    try Task.checkCancellation()
                    guard self.valid(id, capture) else {
                        self.retireIfCurrent(id)
                        return
                    }
                    self.work = nil
                    self.document?.translation = translation
                    self.document?.generating = false
                    self.render()
                    self.startUnits()
                    self.startAnalysis()
                } catch is CancellationError { self.retireIfCurrent(id) } catch {
                    guard self.valid(id, capture) else {
                        self.retireIfCurrent(id)
                        return
                    }
                    self.work = nil
                    self.document?.generating = false
                    self.document?.isError = true
                    self.document?.message = error.localizedDescription
                    self.render()
                }
            }
        }
    }

    private func valid(_ id: UUID, _ capture: LearningReadingSelection) -> Bool {
        revision == id && enabled && sourceAvailability(capture.source) && service.settings.languageLearning.readingEnabled(capture.source)
            && shortcutPermissionValid && reader.isCurrent(capture)
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
        self.document?.expanded.toggle()
        render()
    }

    private func startUnits() {
        unitWork?.cancel()
        guard let document, !document.translation.isEmpty, let recognizer else { return }
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

    private func startAnalysis() {
        analysisWork?.cancel()
        analysisRevision = UUID()
        document?.chunks = []
        if document?.translation.isEmpty == false { document?.message = "" }
        guard let document, !document.translation.isEmpty, service.settings.languageLearning.analysisEnabled else {
            render()
            return
        }
        let id = revision
        let analysisID = analysisRevision
        analysisWork = Task { [weak self] in
            guard let self else { return }
            await LearningRequestTrace.$requestID.withValue(document.traceID) {
                do {
                    let result = try await self.service.analyzeReadingSelection(
                        source: document.capture.text,
                        translation: document.translation, sourceLanguage: document.sourceLanguage,
                        targetLanguage: document.targetLanguage, readingSource: document.capture.source)
                    try Task.checkCancellation()
                    guard self.analysisRevision == analysisID, self.valid(id, document.capture) else { return }
                    self.document?.chunks = result.chunks
                    self.render()
                } catch is CancellationError {} catch {
                    guard !Task.isCancelled, self.analysisRevision == analysisID, self.valid(id, document.capture) else { return }
                    self.document?.message = error.localizedDescription
                    self.render()
                }
            }
        }
    }

    private func render() {
        guard let document, enabled else { return }
        panel.show(
            .init(
                id: document.capture.id, source: document.capture.text, translation: document.translation,
                chunks: document.chunks, sourceLanguage: document.sourceLanguage, targetLanguage: document.targetLanguage,
                caret: document.capture.anchor, isExpanded: document.expanded, isGenerating: document.generating,
                message: document.message, previousTranslation: nil, shortcutLabel: service.settings.languageLearning.keyLabel,
                units: document.units, unitStage: document.unitStage, targetIsSelection: true, canReplace: false,
                isError: document.isError, readingSource: document.capture.source), expand: { [weak self] in self?.toggleDetails() },
            dismiss: { [weak self] in self?.dismiss() },
            replace: nil)
        if !document.translation.isEmpty { service.recordDisplay(source: .translation, requestID: document.traceID) }
        if document.expanded, !document.chunks.isEmpty { service.recordDisplay(source: .analysis, requestID: document.traceID) }
    }

    private func showCaptureError(_ error: Error) {
        beforePresent()
        work = nil
        panel.show(
            .init(
                id: UUID(), source: "", translation: "", chunks: [], sourceLanguage: .english,
                targetLanguage: service.settings.languageLearning.readingTargetLanguage,
                caret: CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 18)),
                isExpanded: false, isGenerating: false, message: error.localizedDescription, previousTranslation: nil,
                shortcutLabel: service.settings.languageLearning.keyLabel, isError: true),
            expand: {}, dismiss: { [weak self] in self?.dismiss() }, replace: nil)
    }

    private func pointer(_ event: NSEvent) {
        guard enabled, !reader.isSelectingRegion else { return }
        if event.type == .leftMouseDown {
            dismiss()
            lastPointerDown = NSEvent.mouseLocation
        } else if event.type == .rightMouseDown || event.type == .scrollWheel {
            dismiss()
        } else if event.type == .leftMouseUp {
            let point = NSEvent.mouseLocation
            let dragged = lastPointerDown.map { hypot($0.x - point.x, $0.y - point.y) > 3 } ?? false
            lastPointerDown = nil
            guard sourceAvailability(.selection), service.settings.languageLearning.selectionTranslationEnabled,
                dragged || event.clickCount >= 2,
                service.settings.selectionIconAllowed(in: frontmostBundle())
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
                        self.service.settings.selectionIconAllowed(in: bundle)
                    else { return }
                    let capture = try await self.reader.capture()
                    try Task.checkCancellation()
                    guard self.revision == id, self.affordanceRevision == iconID, self.reader.isCurrent(capture), self.enabled,
                        capture.bundleIdentifier == bundle,
                        self.service.settings.selectionIconAllowed(in: capture.bundleIdentifier)
                    else { return }
                    self.pendingSelection = capture
                    self.affordanceWork = nil
                    self.icon.show(anchor: capture.anchor) { [weak self, selectionID = capture.id] in
                        guard let self, let pending = self.pendingSelection, pending.id == selectionID else { return }
                        self.begin(pending, fromShortcut: false)
                    }
                } catch { /* Unsupported selections have no passive affordance and send no request. */  }
            }
        }
    }
}
