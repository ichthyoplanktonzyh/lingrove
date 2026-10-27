import Combine
import CoreGraphics
import Foundation
import Logging

/// One app-owned coordinator orchestrates one explicit help session. A saved editor receipt and
/// query revision outlive async generation, while the native panel alone owns IME/editing state.
/// Cancellation invalidates identity before cancelling work so late callbacks cannot reopen UI.
@MainActor
final class ExpressionAssistCoordinator {
    private let settings: SuggestionSettingsModel
    private let focus: any SuggestionFocusProviding
    private let editor: any ExpressionAssistEditing
    private let service: any ExpressionAssistGenerating
    private let panel: any ExpressionAssistPresenting
    private let availability: () -> Bool
    private var subscriptions = Set<AnyCancellable>()
    private var saved: LearningSelectionCapture?
    private var trigger: String?
    private var query = ""
    private var composing = false
    private var running = false
    private var committing = false
    private var acquiringInput = false
    private var probe: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var revision = UUID()
    private var triggerEpoch = UUID()
    private var mutationDeadline: TimeInterval = 0
    private var mutationElement: String?
    var beforePresent: (() -> Void)?
    var isActive: Bool { saved != nil || committing }
    /// AX polling is unnecessary while the native input owns editing. Commit deliberately drops
    /// this hold before restoring the host so the existing exact recapture guards can run.
    var isEditingDescription: Bool { saved != nil && !committing }
    var hasKeyFocus: Bool { panel.hasKeyFocus }

    init(settings: SuggestionSettingsModel, focus: any SuggestionFocusProviding,
         editor: any ExpressionAssistEditing, service: any ExpressionAssistGenerating,
         panel: any ExpressionAssistPresenting, availability: @escaping () -> Bool) {
        self.settings = settings
        self.focus = focus
        self.editor = editor
        self.service = service
        self.panel = panel
        self.availability = availability
    }

    func start() {
        guard !running else { return }
        running = true
        panel.onQueryChanged = { [weak self] in self?.queryChanged($0, composing: $1) }
        panel.onSubmit = { [weak self] in self?.request(immediate: true) }
        panel.onAccept = { [weak self] in self?.finish(with: $0.text) }
        panel.onCancel = { [weak self] in self?.finish(with: nil) }
        panel.onDismissed = { [weak self] in self?.cancel(reason: "panel-dismissed", restoringHost: false) }
        focus.snapshotPublisher.sink { [weak self] snapshot in self?.focusChanged(snapshot) }.store(in: &subscriptions)
        Publishers.MergeMany([settings.languageLearning.expressionAssist.changes,
            settings.languageLearning.explanationChanges,
            settings.languageLearning.$targetLanguage.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$isGloballyEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseState.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.snapshotPublisher.map(\.disabledAppBundleIdentifiers).removeDuplicates().dropFirst()
                .map { _ in () }.eraseToAnyPublisher()
        ]).sink { [weak self] in self?.cancel() }.store(in: &subscriptions)
    }

    func stop() {
        running = false
        cancel()
        subscriptions.removeAll()
        panel.onQueryChanged = nil
        panel.onSubmit = nil
        panel.onAccept = nil
        panel.onCancel = nil
        panel.onDismissed = nil
    }

    /// Shortcut consumption is cheap; AX capture runs after the event tap returns. While the
    /// panel owns input, returning passThrough lets its native text view receive all IME commands.
    func decide(_ event: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        if isActive { return .passThrough }
        let assist = settings.languageLearning.expressionAssist
        guard running, assist.enabled, assist.keyCode != .max, event.keyCode == assist.keyCode,
              ShortcutModifierMask(eventFlags: event.flags) == assist.modifiers,
              settings.expressionAssistShortcutConflict(keyCode: event.keyCode, modifiers: assist.modifiers,
                bundleIdentifier: focus.snapshot.bundleIdentifier) == nil, availability() else { return .notHandled }
        if !event.isAutorepeat {
            let epoch = triggerEpoch
            Task { [weak self] in
                guard let self, self.triggerEpoch == epoch else { return }
                await self.begin(trigger: nil)
            }
        }
        return .consume
    }

    /// Observe mutations, then wait briefly for the host's AX value to catch up. We do not rebuild
    /// Chinese input from physical key events and never trigger from focus entry alone.
    @discardableResult
    func observe(_ event: CapturedInputEvent) -> Bool {
        if isActive { return true }
        let assist = settings.languageLearning.expressionAssist
        guard running, assist.enabled, event.kind == .textMutation,
              ExpressionAssistPolicy.triggerError(assist.trigger) == nil else { return false }
        triggerEpoch = UUID()
        mutationDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        mutationElement = focus.snapshot.context?.elementIdentifier
        // Ordinary letters only arm the existing AX publisher. A bounded explicit refresh is
        // useful for the trigger's final punctuation, not four extra AX walks on every keystroke.
        let ends = assist.trigger == "??" ? ["?", "？"] : [String(assist.trigger.suffix(1))]
        guard ends.contains(where: { event.characters.hasSuffix($0) }) else { return false }
        probe?.cancel()
        let epoch = UUID()
        triggerEpoch = epoch
        probe = Task { [weak self] in
            for _ in 0..<4 {
                guard let self, self.running, !Task.isCancelled, self.triggerEpoch == epoch, !self.isActive else { return }
                self.focus.refreshNow()
                if let context = self.focus.snapshot.context, context.documentSelection.length == 0,
                   !context.hasHostMarkedText, let trigger = ExpressionAssistPolicy.matchedTrigger(
                    beforeCaret: context.precedingText, configured: assist.trigger) {
                    await self.begin(trigger: trigger)
                    return
                }
                try? await Task.sleep(for: .milliseconds(35))
            }
        }
        return false
    }

    private func begin(trigger: String?) async {
        guard running, !isActive, settings.languageLearning.expressionAssist.enabled, availability() else { return }
        LingroveLogger.learning.info("Expression input requested", metadata: ["origin": .string(trigger == nil ? "shortcut" : "trigger")])
        do {
            let capture = try editor.capture(trigger: trigger)
            guard capture.supportsReplacement else {
                LingroveLogger.learning.info("Expression input unavailable", metadata: ["reason": "unsupported_replacement"])
                return
            }
            saved = capture
            self.trigger = trigger
            query = trigger == nil ? capture.source : ""
            revision = UUID()
            let epoch = UUID()
            triggerEpoch = epoch
            acquiringInput = true
            beforePresent?()
            await panel.show(context: capture.context, trigger: trigger ?? "", initialQuery: query)
            guard triggerEpoch == epoch, saved != nil, !committing else { return }
            acquiringInput = false
            guard panel.isVisible, panel.hasKeyFocus, editor.isUnchanged(capture) else {
                LingroveLogger.learning.info("Expression input unavailable", metadata: ["reason": "input_ownership"])
                cancel(); return
            }
            LingroveLogger.learning.info("Expression input opened")
            if !query.isEmpty { request(immediate: false) }
        } catch {
            // A delayed AX read may no longer describe the command the user just typed. Fail open:
            // the original literal trigger stays in the host and no speculative delete is posted.
            LingroveLogger.learning.info("Expression input unavailable", metadata: ["reason": .string(error.localizedDescription)])
            cancel()
        }
    }

    private func queryChanged(_ text: String, composing: Bool) {
        guard saved != nil, !committing else { return }
        guard query != text || self.composing != composing else { return }
        query = text
        self.composing = composing
        request(immediate: false)
    }

    private func request(immediate: Bool) {
        revision = UUID()
        work?.cancel()
        work = nil
        panel.update(result: nil, message: nil, loading: false)
        guard let saved, !committing, !acquiringInput, !composing,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = revision
        let text = query
        let trace = RequestID.generate()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(450)) }
                guard self.revision == id, !Task.isCancelled else { return }
                guard self.editor.isUnchanged(saved) else { self.cancel(reason: "host-receipt-changed"); return }
                LingroveLogger.learning.info("Expression description submitted", metadata: [
                    "query_bytes": .stringConvertible(text.utf8.count)
                ])
                var request = try ExpressionAssistPolicy.request(query: text, value: saved.value, range: saved.range,
                    target: self.settings.languageLearning.targetLanguage,
                    explanation: self.settings.languageLearning.resolvedExplanationLanguage)
                if self.trigger != nil {
                    request = .init(query: request.query, leftContext: request.leftContext, rightContext: request.rightContext,
                        selectedText: "", targetLanguage: request.targetLanguage, explanationLanguage: request.explanationLanguage)
                }
                self.panel.update(result: nil, message: nil, loading: true, request: request)
                let result = try await self.service.generate(request, requestID: trace)
                guard self.revision == id, !Task.isCancelled else { return }
                guard self.editor.isUnchanged(saved) else { self.cancel(reason: "host-receipt-changed"); return }
                self.panel.update(result: result, message: result.clarification, loading: false, request: request)
                self.service.recordDisplay(requestID: trace)
                self.work = nil
            } catch {
                guard self.revision == id, !Task.isCancelled else { return }
                let message = error is CancellationError
                    ? String(localized: "The request was canceled. Press Enter to retry.", table: "Learning")
                    : error.localizedDescription
                self.panel.update(result: nil, message: message, loading: false)
                self.work = nil
            }
        }
    }

    private func focusChanged(_ snapshot: FocusSnapshot) {
        guard let saved else {
            openFromCommittedSnapshot(snapshot)
            return
        }
        // Activation is asynchronous. A temporary focus snapshot describing Lingrove is expected
        // during acquisition; validate the saved host again as soon as input ownership completes.
        guard !committing, !acquiringInput else { return }
        // Native key ownership and outside-click dismissal own the editing lifetime. Polling
        // notifications must not synchronously read the external editor on every local keystroke.
        // Request/result boundaries and the final write still validate its exact saved receipt.
        if panel.hasKeyFocus { return }
        if !panel.isVisible || snapshot.context?.sessionIdentity != saved.context.sessionIdentity {
            cancel(reason: "input-focus-lost")
        }
    }

    private func openFromCommittedSnapshot(_ snapshot: FocusSnapshot) {
        guard running, settings.languageLearning.expressionAssist.enabled,
              ProcessInfo.processInfo.systemUptime < mutationDeadline else { return }
        guard let context = snapshot.context, context.elementIdentifier == mutationElement,
              context.documentSelection.length == 0, !context.hasHostMarkedText else { return }
        guard let trigger = ExpressionAssistPolicy.matchedTrigger(beforeCaret: context.precedingText,
            configured: settings.languageLearning.expressionAssist.trigger) else { return }
        mutationDeadline = 0
        let epoch = triggerEpoch
        Task { [weak self] in
            guard let self, self.triggerEpoch == epoch else { return }
            await self.begin(trigger: trigger)
        }
    }

    private func finish(with insertion: String?) {
        guard let saved, !committing, !composing else { return }
        // Cancel discards only our temporary query. A symbol invocation also removes its exact
        // marker, but an explicit shortcut with a selection never deletes the user's source.
        let replacement = insertion ?? (trigger != nil ? "" : nil)
        committing = true
        acquiringInput = false
        revision = UUID()
        let id = revision
        work?.cancel()
        panel.hide(restoringHost: true)
        guard let replacement else { cancel(); return }
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let resumed = try await self.resumeForCommit(saved, id: id)
                guard self.availability() else { throw CancellationError() }
                try await self.editor.replace(resumed, text: replacement)
                guard self.revision == id else { return }
                self.cancel()
            } catch {
                // A write can be uncertain. Never retry or roll back an editor mutation; a new
                // invocation must capture the host again. Failed preflight leaves its text intact.
                guard self.revision == id else { return }
                self.cancel()
                if let insertion {
                    self.panel.showFailure(context: saved.context, text: insertion,
                        message: String(localized: "The insertion could not be verified. Check the editor before copying this candidate.",
                            table: "Learning"))
                }
            }
        }
    }

    /// Activation and AX settle independently: two successful receipts in the same new focus
    /// session, separated by a run-loop interval, acknowledge the return. Each editor resume also
    /// checks the shared write preflight. These are read-only retries; a write is dispatched once.
    private func resumeForCommit(_ saved: LearningSelectionCapture, id: UUID) async throws -> LearningSelectionCapture {
        var stableSession: FocusedInputSessionIdentity?
        for _ in 0..<12 {
            try Task.checkCancellation()
            guard revision == id else { throw CancellationError() }
            if let capture = try? editor.resume(saved) {
                if stableSession == capture.context.sessionIdentity { return capture }
                stableSession = capture.context.sessionIdentity
            } else {
                stableSession = nil
            }
            try await Task.sleep(for: .milliseconds(35))
        }
        throw CancellationError()
    }

    func cancel(reason: String = "cancelled", restoringHost: Bool = true) {
        if isActive { LingroveLogger.learning.info("Expression input closed", metadata: ["reason": .string(reason)]) }
        revision = UUID()
        triggerEpoch = UUID()
        probe?.cancel()
        probe = nil
        work?.cancel()
        work = nil
        saved = nil
        trigger = nil
        query = ""
        composing = false
        mutationDeadline = 0
        mutationElement = nil
        committing = false
        acquiringInput = false
        panel.hide(restoringHost: restoringHost)
    }
}
