import ApplicationServices
import Foundation
import Testing
@testable import Lingrove

/// Holds model replies independently of task cancellation, exercising the same late-response
/// problem as an endpoint. Editor and panel doubles never read or write the user's applications.
@MainActor
struct ExpressionAssistCoordinatorTests {
    @Test
    func shortcutOpensIsolatedInputWhileTranslationIsDisabled() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        #expect(!rig.settings.languageLearning.translationEnabled)
        rig.coordinator.start()
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await waitUntil { rig.panel.isVisible }
        #expect(rig.panel.initialQuery.isEmpty)
        #expect(rig.service.requests.isEmpty && rig.editor.writes.isEmpty)
        #expect(rig.coordinator.decide(.init(keyCode: 36, flags: [])) == .passThrough)
        rig.panel.onQueryChanged?("排除缓存是原因", false)
        rig.panel.onSubmit?()
        await waitUntil { rig.service.requests.count == 1 }
        let request = try #require(rig.service.requests.first)
        #expect(request.leftContext == "We still can't ")
        #expect(request.rightContext == " yet.")
        #expect(rig.editor.writes.isEmpty)
        rig.service.complete(0, text: "rule out caching as the cause")
        await waitUntil { rig.panel.result != nil }
        rig.panel.onAccept?(try #require(rig.panel.result?.candidates.first))
        await waitUntil { rig.editor.writes.count == 1 }
        #expect(rig.editor.writes == ["rule out caching as the cause"])
        #expect(rig.editor.resumptions == 2)
    }

    @Test
    func compositionDoesNotGenerateOrCommitAndOldRepliesCannotReplaceANewerQuery() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        _ = rig.coordinator.decide(rig.shortcut)
        await waitUntil { rig.panel.isVisible }
        rig.panel.onQueryChanged?("排除", true)
        rig.panel.onSubmit?()
        await Task.yield()
        #expect(rig.service.requests.isEmpty)
        rig.panel.onQueryChanged?("排除缓存", false)
        rig.panel.onSubmit?()
        await waitUntil { rig.service.requests.count == 1 }
        rig.panel.onQueryChanged?("排除网络", false)
        #expect(rig.panel.result == nil)
        rig.panel.onSubmit?()
        await waitUntil { rig.service.requests.count == 2 }
        rig.service.complete(1, text: "rule out a network issue")
        await waitUntil { rig.panel.result != nil }
        rig.service.complete(0, text: "rule out caching")
        for _ in 0..<10 { await Task.yield() }
        #expect(rig.panel.result?.candidates.first?.text == "rule out a network issue")
        #expect(rig.editor.writes.isEmpty)
    }

    @Test
    func symbolInvocationRequiresAnEditAndCancellationDeletesOnlyItsMarker() async throws {
        let rig = try Rig(preceding: "We still can't ??")
        defer { rig.cleanup() }
        rig.coordinator.start()
        await Task.yield()
        #expect(!rig.panel.isVisible)
        _ = rig.coordinator.observe(LingroveTestFixtures.inputEvent(kind: .textMutation, characters: "?"))
        await waitUntil { rig.panel.isVisible }
        #expect(rig.editor.lastTrigger == "??")
        rig.panel.onQueryChanged?("未提交的描述", false)
        rig.panel.onCancel?()
        await waitUntil { rig.editor.writes.count == 1 }
        #expect(rig.editor.writes == [""])
        #expect(rig.editor.lastCapture?.source == "??")
    }

    @Test(arguments: ["stop", "disable", "outside"])
    func invalidationRejectsLateResultsAndNeverDeletesTheOriginal(_ invalidation: String) async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        _ = rig.coordinator.decide(rig.shortcut)
        await waitUntil { rig.panel.isVisible }
        rig.panel.onQueryChanged?("示例", false)
        rig.panel.onSubmit?()
        await waitUntil { rig.service.requests.count == 1 }
        switch invalidation {
        case "stop": rig.coordinator.stop()
        case "disable": rig.settings.languageLearning.expressionAssist.enabled = false
        default: rig.panel.onDismissed?()
        }
        rig.service.complete(0, text: "example")
        for _ in 0..<10 { await Task.yield() }
        #expect(!rig.panel.isVisible && rig.panel.result == nil)
        #expect(rig.editor.writes.isEmpty)
    }

    @Test
    func failedWriteKeepsACopyOnlyCandidateWithoutRetrying() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.editor.failWrite = true
        rig.coordinator.start()
        _ = rig.coordinator.decide(rig.shortcut)
        await waitUntil { rig.panel.isVisible }
        rig.panel.onAccept?(.init(text: "rule out caching", hint: ""))
        await waitUntil { rig.panel.failure != nil }
        #expect(rig.editor.writes.count == 1)
        #expect(rig.panel.failure == "rule out caching")
        #expect(!rig.coordinator.isActive)
    }

    @Test
    func ordinaryLettersUseTheExistingFocusPublisherInsteadOfExtraAXWalks() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        _ = rig.coordinator.observe(LingroveTestFixtures.inputEvent(kind: .textMutation, characters: "a"))
        for _ in 0..<10 { await Task.yield() }
        #expect(rig.focus.refreshCount == 0)
        _ = rig.coordinator.decide(rig.shortcut)
        rig.coordinator.stop()
        for _ in 0..<10 { await Task.yield() }
        #expect(rig.editor.captures == 0)
    }

    @Test
    func activationSnapshotsAndTypingDuringAcquisitionDoNotInvalidateTheOwnedSession() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.panel.delayPresentation = true
        rig.coordinator.start()
        _ = rig.coordinator.decide(rig.shortcut)
        await waitUntil { rig.panel.presentation != nil }
        rig.focus.publish(precedingText: "", focusChangeSequence: 20)
        rig.panel.onQueryChanged?("排除缓存", false)
        rig.panel.completePresentation()
        await waitUntil { rig.panel.hasKeyFocus }
        #expect(rig.coordinator.isActive)
        rig.panel.onSubmit?()
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.complete(0, text: "rule out caching")
        await waitUntil { rig.panel.result != nil }
        #expect(rig.editor.writes.isEmpty)
        rig.panel.onDismissed?()
        #expect(!rig.coordinator.isActive && rig.panel.lastRestoreHost == false)
    }

    @Test
    func cancellingWhileActivationIsPendingCannotReopenTheInput() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.panel.delayPresentation = true
        rig.coordinator.start()
        _ = rig.coordinator.decide(rig.shortcut)
        await waitUntil { rig.panel.presentation != nil }
        rig.coordinator.stop()
        for _ in 0..<10 { await Task.yield() }
        #expect(!rig.coordinator.isActive && !rig.panel.isVisible)
        #expect(rig.service.requests.isEmpty && rig.editor.writes.isEmpty)
    }

    @Test
    func transientReturnReceiptsAreRetriedBeforeOneWriteAndPersistentFailureNeverWrites() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.editor.unavailableResumptions = 2
        rig.coordinator.start()
        _ = rig.coordinator.decide(rig.shortcut)
        await waitUntil { rig.panel.isVisible }
        rig.panel.onAccept?(.init(text: "rule out caching", hint: ""))
        #expect(rig.coordinator.isActive && !rig.coordinator.isEditingDescription,
            "Commit must release the AX capture hold before trying to resume the original field")
        await waitUntil { rig.editor.writes.count == 1 }
        #expect(rig.editor.resumptions == 4, "Two failed reads are followed by two agreeing receipts")
        #expect(rig.editor.writes == ["rule out caching"])

        await waitUntil { !rig.coordinator.isActive }
        rig.editor.unavailableResumptions = .max
        _ = rig.coordinator.decide(rig.shortcut)
        await waitUntil { rig.panel.isVisible }
        rig.panel.onAccept?(.init(text: "another candidate", hint: ""))
        await waitUntil { rig.panel.failure != nil }
        #expect(rig.editor.writes.count == 1, "A failed return never reaches the write boundary")
    }

    @Test
    func localFocusUpdatesDoNotReadTheHostAndRequestsStillRejectAChangedReceipt() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        _ = rig.coordinator.decide(rig.shortcut)
        await waitUntil { rig.panel.hasKeyFocus }
        let initialChecks = rig.editor.unchangedChecks
        for sequence in 2...40 {
            rig.focus.publish(precedingText: "", focusChangeSequence: UInt64(sequence))
            rig.panel.onQueryChanged?("p\(sequence)", true)
        }
        #expect(rig.coordinator.isEditingDescription)
        #expect(rig.editor.unchangedChecks == initialChecks)
        #expect(rig.service.requests.isEmpty)
        rig.editor.unchanged = false
        rig.panel.onQueryChanged?("排除缓存", false)
        rig.panel.onSubmit?()
        await waitUntil { !rig.coordinator.isActive }
        #expect(rig.editor.unchangedChecks > initialChecks)
        #expect(rig.service.requests.isEmpty && rig.editor.writes.isEmpty)
    }

    @Test
    func committedQueryStillUsesTheExistingAutomaticDebounce() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        _ = rig.coordinator.decide(rig.shortcut)
        await waitUntil { rig.panel.hasKeyFocus }
        rig.panel.onQueryChanged?("排除缓存", false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.service.requests.isEmpty)
        await waitUntil { rig.service.requests.count == 1 }
        #expect(rig.service.requests.first?.query == "排除缓存")
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Expression session did not reach the expected state")
    }

    @MainActor
    private final class Rig {
        let suite: String
        let defaults: UserDefaults
        let settings: SuggestionSettingsModel
        let focus: InlineFeatureFocusStub
        let editor: Editor
        let service = Service()
        let panel = Panel()
        let coordinator: ExpressionAssistCoordinator
        let shortcut = InputMonitorKeyEvent(keyCode: 4, flags: [.maskControl, .maskAlternate, .maskShift])

        init(preceding: String = "We still can't ") throws {
            suite = "test.expressionCoordinator.\(UUID())"
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
            settings.setGloballyEnabled(true)
            settings.languageLearning.expressionAssist.enabled = true
            settings.languageLearning.expressionAssist.keyCode = 4
            settings.languageLearning.expressionAssist.modifiers = [.control, .option, .shift]
            focus = InlineFeatureFocusStub(precedingText: preceding)
            editor = Editor(preceding: preceding)
            coordinator = ExpressionAssistCoordinator(settings: settings, focus: focus, editor: editor,
                service: service, panel: panel, availability: { true })
        }
        func cleanup() {
            coordinator.stop()
            service.finishPending()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private final class Editor: ExpressionAssistEditing {
        let preceding: String
        var captures = 0
        var resumptions = 0
        var lastTrigger: String?
        var lastCapture: LearningSelectionCapture?
        var writes: [String] = []
        var failWrite = false
        var unavailableResumptions = 0
        var unchanged = true
        var unchangedChecks = 0
        init(preceding: String) { self.preceding = preceding }
        func capture(trigger: String?) throws -> LearningSelectionCapture {
            captures += 1
            lastTrigger = trigger
            let context = LingroveTestFixtures.focusedInputSnapshot(precedingText: preceding, trailingText: " yet.")
            let length = trigger?.utf16.count ?? 0
            let capture = LearningSelectionCapture(element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                context: context, value: preceding + " yet.",
                range: NSRange(location: preceding.utf16.count - length, length: length), source: trigger ?? "",
                usesExplicitRange: true, inputMethodAssessment: .replacementAllowed(.explicitlyEmpty))
            lastCapture = capture
            return capture
        }
        func isUnchanged(_ saved: LearningSelectionCapture) -> Bool { unchangedChecks += 1; return unchanged }
        func resume(_ saved: LearningSelectionCapture) throws -> LearningSelectionCapture {
            resumptions += 1
            if unavailableResumptions > 0 {
                unavailableResumptions -= 1
                throw VocabularyError.invalidContent
            }
            return saved
        }
        func replace(_ saved: LearningSelectionCapture, text: String) async throws {
            writes.append(text)
            if failWrite { throw VocabularyError.invalidContent }
        }
    }

    private final class Service: ExpressionAssistGenerating {
        var requests: [ExpressionAssistRequest] = []
        var pending: [CheckedContinuation<ExpressionAssistResult, Error>?] = []
        func generate(_ request: ExpressionAssistRequest, requestID: String) async throws -> ExpressionAssistResult {
            requests.append(request)
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func complete(_ index: Int, text: String) {
            guard pending.indices.contains(index) else { Issue.record("Missing model request"); return }
            pending[index]?.resume(returning: .init(candidates: [.init(text: text, hint: "")]))
            pending[index] = nil
        }
        func finishPending() {
            for index in pending.indices { pending[index]?.resume(throwing: CancellationError()); pending[index] = nil }
        }
        func recordDisplay(requestID: String) {}
    }

    private final class Panel: ExpressionAssistPresenting {
        var isVisible = false
        var hasKeyFocus = false
        var onQueryChanged: ((String, Bool) -> Void)?
        var onSubmit: (() -> Void)?
        var onAccept: ((ExpressionAssistCandidate) -> Void)?
        var onCancel: (() -> Void)?
        var onDismissed: (() -> Void)?
        var initialQuery = ""
        var result: ExpressionAssistResult?
        var failure: String?
        var delayPresentation = false
        var presentation: CheckedContinuation<Void, Never>?
        var lastRestoreHost: Bool?
        func show(context: FocusedInputSnapshot, trigger: String, initialQuery: String) async {
            isVisible = true; self.initialQuery = initialQuery
            if delayPresentation { await withCheckedContinuation { presentation = $0 } }
            if isVisible { hasKeyFocus = true }
        }
        func completePresentation() { presentation?.resume(); presentation = nil }
        func update(result: ExpressionAssistResult?, message: String?, loading: Bool) { self.result = result }
        func hide(restoringHost: Bool) {
            lastRestoreHost = restoringHost
            isVisible = false; hasKeyFocus = false; result = nil
            completePresentation()
        }
        func showFailure(context: FocusedInputSnapshot, text: String, message: String) { failure = text }
    }
}
