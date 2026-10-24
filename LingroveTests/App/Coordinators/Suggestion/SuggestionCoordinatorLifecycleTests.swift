import Foundation
import XCTest
@testable import Lingrove

/// Locks the coordinator's lifecycle commands, the settings-change reaction, and the callbacks it
/// installs on its collaborators at construction: what gets torn down on stop and model switches,
/// which settings edits restart the pipeline, and how overlay and visual-context events feed back
/// into the state machine. A regression here leaks callbacks across shutdown, leaves stale
/// suggestions alive across a model swap, or lets the accept tap own Tab with nothing on screen.
final class SuggestionCoordinatorLifecycleTests: SuggestionCoordinatorRigTestCase {
    func test_completionOffDropsReadyGhostAndRapidAcceptanceButKeepsInlineInputObservers() async {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig)
        rig.coordinator.armPostExhaustionAcceptance()
        var inlineEvents = 0
        rig.coordinator.emojiInputObserver = { _ in inlineEvents += 1; return true }
        var off = rig.coordinator.settingsSnapshot
        off.isCompletionEnabled = false
        rig.coordinator.handleSuggestionSettingsChange(off)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed)
        XCTAssertFalse(rig.inputMonitor.shouldConsumeAcceptKeyProvider())
        XCTAssertNotNil(rig.inputMonitor.onEvent)
        XCTAssertFalse(rig.coordinator.handleInputEvent(LingroveTestFixtures.inputEvent(kind: .textMutation, characters: ":")),
                       "Inline observation survives; actual key consumption belongs to the input tap")
        XCTAssertEqual(inlineEvents, 1)
        rig.coordinator.emojiInputObserver = nil
        XCTAssertFalse(rig.coordinator.handleInputEvent(LingroveTestFixtures.inputEvent(kind: .acceptance)))
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
        XCTAssertTrue(rig.visualContext.startedSessions.isEmpty)
        XCTAssertNil(rig.coordinator.currentVisualRefreshContext())
        XCTAssertGreaterThan(rig.engine.prewarmCancellationCount, 0)
        await rig.coordinator.awaitCachedGenerationContextResetIfNeeded()
    }

    func test_completionOffCancelsPendingPredictionAndFocusPrewarmThenReenablesInTheSameField() async {
        let rig = retained(makeCoordinatorRig(settingsSnapshot: LingroveTestFixtures.settingsSnapshot(debounceMilliseconds: 1)))
        rig.coordinator.handleSupportedSnapshot(rig.focusProvider.snapshot)
        let capturesBeforeDisable = rig.visualContext.startedSessions.count
        rig.coordinator.schedulePrediction()
        var settings = rig.coordinator.settingsSnapshot
        settings.isCompletionEnabled = false
        rig.coordinator.handleSuggestionSettingsChange(settings)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(rig.engine.prewarmedRequests.isEmpty, "The cancelled focus task must not cross its reset barrier")
        XCTAssertTrue(rig.engine.requests.isEmpty)
        rig.coordinator.handleSupportedSnapshot(rig.focusProvider.snapshot)
        XCTAssertEqual(rig.visualContext.startedSessions.count, capturesBeforeDisable)
        settings.isCompletionEnabled = true
        rig.coordinator.handleSuggestionSettingsChange(settings)
        await waitUntil("Re-enabling must use the current focus without a focus change") {
            !rig.engine.requests.isEmpty
        }
    }

    func test_completionOffRejectsLatePartialsAndFinalReplyFromAnUncooperativeEngine() async {
        let rig = retained(makeCoordinatorRig(settingsSnapshot: LingroveTestFixtures.settingsSnapshot(
            debounceMilliseconds: 1, streamSuggestionsWhileGenerating: true)))
        var finish: CheckedContinuation<Void, Never>?
        rig.engine.resultProvider = { request in
            await withCheckedContinuation { finish = $0 }
            return SuggestionResult(generation: request.generation, rawText: " world", text: " world", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil("Engine never started") { finish != nil }
        let request = rig.engine.requests[0]
        var off = rig.coordinator.settingsSnapshot
        off.isCompletionEnabled = false
        rig.coordinator.handleSuggestionSettingsChange(off)
        rig.engine.latestPartial?(SuggestionResult(generation: request.generation, rawText: " world", text: " world", latency: 0.01))
        finish?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertFalse(rig.inputMonitor.shouldConsumeAcceptKeyProvider())
    }

    func test_completionOffBlocksAutomaticCorrectionAndDictionaryFallback() async {
        var off = LingroveTestFixtures.settingsSnapshot(
            debounceMilliseconds: 1, suppressCompletionsOnTypo: true,
            offerTypoCorrections: true, automaticallyFixTypos: true)
        off.isCompletionEnabled = false
        for text in ["I typed recieve ", "comple"] {
            let rig = retained(makeCoordinatorRig(
                snapshot: LingroveTestFixtures.focusedInputSnapshot(precedingText: text), settingsSnapshot: off))
            rig.coordinator.schedulePrediction()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(rig.engine.requests.isEmpty)
            XCTAssertTrue(rig.inserter.replacements.isEmpty)
            XCTAssertNil(rig.interactionState.activeSession)
            XCTAssertFalse(rig.coordinator.overlayState.isVisible)
            XCTAssertNil(rig.coordinator.preparedContinuation)
            XCTAssertNil(rig.coordinator.typingPrediction)
        }
    }

    // MARK: - Lifecycle commands

    func test_start_reconcilesOutOfAStaleDisabledState() {
        let rig = retained(makeCoordinatorRig())
        rig.coordinator.state = .disabled("stale launch state")

        rig.coordinator.start()

        XCTAssertEqual(rig.coordinator.state, .idle)
    }

    func test_start_disablesWhenTheEnvironmentIsBlocked() {
        let rig = retained(makeCoordinatorRig(
            settingsSnapshot: LingroveTestFixtures.settingsSnapshot(isGloballyEnabled: false)
        ))

        rig.coordinator.start()

        XCTAssertEqual(rig.coordinator.state, .disabled("Lingrove is turned off."))
    }

    func test_stop_detachesEveryLongLivedCallbackAndHidesTheOverlay() async {
        let rig = retained(makeCoordinatorRig())
        // The coordinator wires these at construction; overwriting them here would sever its own
        // overlay-state mirror and fake the assertion below, so verify the wiring instead.
        XCTAssertNotNil(rig.inputMonitor.onEvent, "Construction must install the event callback")
        XCTAssertNotNil(rig.overlayController.onStateChange)
        XCTAssertNotNil(rig.visualContext.refreshContextProvider)
        rig.overlayController.showSuggestion(" ghost", geometry: LingroveTestFixtures.overlayGeometry())
        XCTAssertTrue(rig.coordinator.overlayState.isVisible)

        rig.coordinator.stop()

        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.visualContext.cancelCalls, [true])
        XCTAssertNil(rig.inputMonitor.onEvent, "A leaked event callback outlives shutdown")
        XCTAssertNil(rig.inputMonitor.onSuppressedSyntheticInput)
        XCTAssertNil(rig.overlayController.onStateChange)
        XCTAssertNil(rig.visualContext.onStateChange)
        XCTAssertNil(rig.visualContext.onInjectedContextReady)
        XCTAssertNil(rig.visualContext.refreshContextProvider)
        // Shutdown also drops the engine's cached generation context through the reset barrier.
        await rig.coordinator.awaitCachedGenerationContextResetIfNeeded()
        XCTAssertEqual(rig.engine.resetCount, 1)
    }

    func test_prepareForRuntimeModelSwitch_clearsTheActiveSessionAndOverlay() async {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig)
        rig.coordinator.latestGenerationNumber = 4
        rig.coordinator.latestRequestID = "req_previous"

        rig.coordinator.prepareForRuntimeModelSwitch()

        XCTAssertNil(rig.interactionState.activeSession, "A stale session must not survive a model swap")
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertEqual(rig.visualContext.cancelCalls, [true])
        XCTAssertNil(rig.coordinator.latestGenerationNumber, "Diagnostics from the old model are cleared")
        XCTAssertNil(rig.coordinator.latestRequestID)
        await rig.coordinator.awaitCachedGenerationContextResetIfNeeded()
        XCTAssertEqual(rig.engine.resetCount, 1)
    }

    // MARK: - Settings changes

    func test_settingsChange_identicalSnapshotIsANoOp() {
        let rig = retained(makeCoordinatorRig())
        rig.overlayController.showSuggestion(" keep me", geometry: LingroveTestFixtures.overlayGeometry())

        rig.coordinator.handleSuggestionSettingsChange(rig.coordinator.settingsSnapshot)

        XCTAssertTrue(rig.coordinator.overlayState.isVisible, "An unchanged snapshot must not reset anything")
        XCTAssertTrue(rig.visualContext.cancelCalls.isEmpty)
    }

    func test_settingsChange_engineSwitchResetsStateAndRestartsThePipeline() {
        let rig = retained(makeCoordinatorRig())
        rig.overlayController.showSuggestion(" stale", geometry: LingroveTestFixtures.overlayGeometry())

        let switched = LingroveTestFixtures.settingsSnapshot(
            selectedEngine: .appleIntelligence,
            debounceMilliseconds: 1
        )
        rig.coordinator.handleSuggestionSettingsChange(switched)

        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.coordinator.settingsSnapshot, switched)
        // The obsolete visual context is cancelled, then a supported focus environment restarts
        // exactly one OCR session and schedules prediction.
        XCTAssertEqual(rig.visualContext.cancelCalls, [true])
        XCTAssertEqual(rig.visualContext.startedSessions, [rig.focusProvider.snapshot.context!])
        XCTAssertEqual(rig.coordinator.state, .debouncing)
    }

    func test_settingsChangesThatDisableTheSubsystemDoNotRestartThePipeline() {
        let cases = [
            DisablingChange(
                name: "globally disabled",
                lowPowerModeEnabled: false,
                snapshot: LingroveTestFixtures.settingsSnapshot(isGloballyEnabled: false, debounceMilliseconds: 1)
            ),
            DisablingChange(
                name: "temporarily paused",
                lowPowerModeEnabled: false,
                snapshot: LingroveTestFixtures.settingsSnapshot(isTemporarilyPaused: true, debounceMilliseconds: 1)
            ),
            // Low Power Mode is already on; opting into auto-disable must take effect immediately.
            DisablingChange(
                name: "auto-disable while in Low Power Mode",
                lowPowerModeEnabled: true,
                snapshot: LingroveTestFixtures.settingsSnapshot(
                    isLowPowerModeAutoDisableEnabled: true,
                    debounceMilliseconds: 1
                )
            )
        ]

        for testCase in cases {
            let rig = retained(makeCoordinatorRig(
                lowPowerModeEnabled: testCase.lowPowerModeEnabled,
                settingsSnapshot: LingroveTestFixtures.settingsSnapshot(
                    isLowPowerModeAutoDisableEnabled: false,
                    debounceMilliseconds: 1
                )
            ))

            rig.coordinator.handleSuggestionSettingsChange(testCase.snapshot)

            XCTAssertEqual(rig.coordinator.state, .idle, "\(testCase.name): a disabling change must not schedule")
            XCTAssertTrue(rig.visualContext.startedSessions.isEmpty, "\(testCase.name): no OCR for a disabled subsystem")
            // The obsolete visual context is still torn down.
            XCTAssertEqual(rig.visualContext.cancelCalls, [true], testCase.name)
        }
    }

    // MARK: - Visual refresh authorization

    func test_visualRefreshContext_returnsTheFreshlyReadFieldWhenCaptureIsAllowed() {
        let rig = retained(makeCoordinatorRig())

        XCTAssertEqual(rig.coordinator.currentVisualRefreshContext(), rig.focusProvider.snapshot.context)
        XCTAssertEqual(rig.focusProvider.refreshCount, 1, "Capture authorization always pays a fresh AX read")
    }

    func test_visualRefreshContext_refreshesEvenImmediatelyAfterPoll() {
        let rig = retained(makeCoordinatorRig())
        rig.focusProvider.millisecondsSinceLastCapture = 1
        rig.focusProvider.onRefresh = { [weak focus = rig.focusProvider] in
            focus?.snapshot = .inactive
        }

        XCTAssertNil(
            rig.coordinator.currentVisualRefreshContext(),
            "A window switch right after a poll must not authorize capturing the old field"
        )
        XCTAssertEqual(rig.focusProvider.refreshCount, 1)
    }

    func test_visualRefreshContext_declinesSecureFieldsAndMissingScreenRecording() {
        let secureRig = retained(makeCoordinatorRig(
            snapshot: LingroveTestFixtures.focusedInputSnapshot(isSecure: true)
        ))
        XCTAssertNil(secureRig.coordinator.currentVisualRefreshContext(), "Password fields are never captured")

        let deniedRig = retained(makeCoordinatorRig())
        deniedRig.permissionProvider.screenRecordingGranted = false
        XCTAssertNil(deniedRig.coordinator.currentVisualRefreshContext())
    }

    // MARK: - Collaborator callbacks

    func test_overlayVisibilityTogglesAcceptInterception() {
        let rig = retained(makeCoordinatorRig())

        rig.overlayController.showSuggestion(" world", geometry: LingroveTestFixtures.overlayGeometry())
        rig.overlayController.hide(reason: "test")

        // Only sit in the keystroke critical path while ghost text is actually visible (issue #328).
        XCTAssertEqual(rig.inputMonitor.acceptInterceptionRequests, [true, false])
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
    }

    func test_visualContextStateIsMirroredIntoPublishedProperties() {
        let rig = retained(makeCoordinatorRig())

        rig.visualContext.onStateChange?(.ready, "Screen excerpt")

        XCTAssertEqual(rig.coordinator.visualContextStatus, .ready)
        XCTAssertEqual(rig.coordinator.latestVisualContextText, "Screen excerpt")
    }

    func test_losingScreenContextWhileDisabledKeepsTheDisabledState() {
        let rig = retained(makeCoordinatorRig())
        rig.visualContext.onStateChange?(.ready, "Previous conversation")
        rig.coordinator.disablePredictions(reason: "Lingrove is turned off.")

        rig.visualContext.onStateChange?(.unavailable("Expired"), nil)

        XCTAssertEqual(
            rig.coordinator.state,
            .disabled("Lingrove is turned off."),
            "Invalidated screen text must not re-enable a disabled pipeline"
        )
        XCTAssertNil(rig.coordinator.latestVisualContextText)
    }

    func test_injectedContextForAnotherFieldIsIgnored() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig)
        let identity = rig.focusProvider.snapshot.context!.identity
        let otherField = FocusedInputIdentity(
            elementIdentifier: identity.elementIdentifier,
            focusChangeSequence: identity.focusChangeSequence &+ 1
        )

        rig.visualContext.onInjectedContextReady?(otherField)

        XCTAssertTrue(rig.coordinator.overlayState.isVisible, "Another field's screen text cannot retire this tail")
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " world")
        XCTAssertEqual(rig.coordinator.state, .idle)
    }

    /// One settings edit that should leave the subsystem off, plus the environment it lands in.
    private struct DisablingChange {
        let name: String
        let lowPowerModeEnabled: Bool
        let snapshot: SuggestionSettingsSnapshot
    }
}
