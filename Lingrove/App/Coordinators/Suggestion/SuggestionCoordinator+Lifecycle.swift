import Foundation
import Logging

/// File overview:
/// Lifecycle entry points and user preference changes for `SuggestionCoordinator`.
/// These methods are the closest thing this subsystem has to "public commands" from the app and UI.
extension SuggestionCoordinator {
    // MARK: - Lifecycle

    /// Reconciles coordinator state with the current permission and focus environment.
    func start() {
        LingroveLogger.suggestion.info("Suggestion coordinator starting")
        reconcileWithCurrentEnvironment()
    }

    /// Cancels any pending work and detaches long-lived callbacks during shutdown.
    func stop() {
        LingroveLogger.suggestion.info("Suggestion coordinator stopping")
        suggestionPresentationTiming.clear()
        doubleTapAcceptanceState.reset()
        releasePostExhaustionAcceptanceWindow()
        cancelEnginePrewarm()
        cancelPredictionWork()
        resetCachedGenerationContext()
        suggestionAnchorCache = SuggestionAnchorCache()
        visualContextCoordinator.cancel(resetState: true)
        hideOverlay(reason: "Overlay hidden because Lingrove stopped observing suggestions.")
        inputMonitor.onEvent = nil
        inputMonitor.onSuppressedSyntheticInput = nil
        overlayController.onStateChange = nil
        visualContextCoordinator.onStateChange = nil
        visualContextCoordinator.onInjectedContextReady = nil
        visualContextCoordinator.refreshContextProvider = nil
    }

    /// Clears any active suggestion work before the runtime swaps to a different model.
    /// This prevents stale completions from the previous model from surviving the switch.
    func prepareForRuntimeModelSwitch() {
        LingroveLogger.suggestion.info("Preparing for runtime model switch, clearing active state")
        suggestionPresentationTiming.clear()
        doubleTapAcceptanceState.reset()
        releasePostExhaustionAcceptanceWindow()
        cancelEnginePrewarm()
        cancelPredictionWork()
        resetCachedGenerationContext()
        suggestionAnchorCache = SuggestionAnchorCache()
        interactionState.resetAll()
        visualContextCoordinator.cancel(resetState: true)
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because the runtime model is switching.")
        state = .idle
    }

    func cancelEnginePrewarm() {
        prewarmTask?.cancel()
        prewarmTask = nil
        suggestionEngine.cancelPrewarm()
    }

    // MARK: - Settings

    /// The coordinator reacts to settings changes instead of owning those preferences directly.
    /// That separation keeps "user configuration" distinct from "active autocomplete session."
    func handleSuggestionSettingsChange(_ snapshot: SuggestionSettingsSnapshot) {
        guard settingsSnapshot != snapshot else {
            return
        }

        LingroveLogger.suggestion.info("Settings changed, resetting suggestion state")
        settingsSnapshot = snapshot
        doubleTapAcceptanceState.reset()
        releasePostExhaustionAcceptanceWindow()
        cancelEnginePrewarm()
        cancelPredictionWork()
        resetCachedGenerationContext()
        // Field text can stay identical while its app instructions or backend change. Reusing a
        // text-only anchor here would bypass request construction with the new settings entirely.
        suggestionAnchorCache = SuggestionAnchorCache()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because autocomplete settings changed.")
        interactionState.resetAll()
        state = .idle

        // Keep the shared input callback alive for learning, emoji, macros, and history. Only
        // autocomplete is disabled, and its acceptance state must be retired immediately.
        if !snapshot.isCompletionEnabled {
            visualContextCoordinator.cancel(resetState: true)
            state = .disabled(currentDisabledReason(focusSnapshot: focusModel.snapshot)
                ?? String(localized: "Autocomplete is turned off", table: "Learning"))
            return
        }

        // Cancel any obsolete context, then restart only when the subsystem is not disabled.
        visualContextCoordinator.cancel(resetState: true)
        if let focusedSnapshot = focusModel.snapshot.context,
           SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
               globallyEnabled: settingsSnapshot.isGloballyEnabled,
               completionEnabled: settingsSnapshot.isCompletionEnabled,
               temporarilyPaused: settingsSnapshot.isTemporarilyPaused,
               isLowPowerModeActive: lowPowerModeProvider.isLowPowerModeEnabled,
               isLowPowerModeAutoDisableEnabled: settingsSnapshot.isLowPowerModeAutoDisableEnabled,
               disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
               disabledDomains: PerDomainDisableSettings.disabledDomains(),
               suggestInIntegratedTerminals: settingsSnapshot.suggestInIntegratedTerminals,
               inputMonitoringGranted: permissionManager.inputMonitoringGranted,
               screenRecordingGranted: permissionManager.screenRecordingGranted,
               focusSnapshot: focusModel.snapshot,
               isFastModeEnabled: settingsSnapshot.isFastModeEnabled
           ) {
            visualContextCoordinator.startSessionIfNeeded(
                for: focusedSnapshot, configuration: .forEngine(settingsSnapshot.selectedEngine)
            )
        }

        if SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            completionEnabled: settingsSnapshot.isCompletionEnabled,
            temporarilyPaused: settingsSnapshot.isTemporarilyPaused,
            isLowPowerModeActive: lowPowerModeProvider.isLowPowerModeEnabled,
            isLowPowerModeAutoDisableEnabled: settingsSnapshot.isLowPowerModeAutoDisableEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            disabledDomains: PerDomainDisableSettings.disabledDomains(),
            suggestInIntegratedTerminals: settingsSnapshot.suggestInIntegratedTerminals,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusModel.snapshot
        ) {
            schedulePrediction()
        }
    }

    /// Called by the visual service's slow refresh timer. Orchestration owns permission/settings
    /// policy; the service owns the timer and pixels. A fresh AX read prevents a background capture
    /// from using the field that was focused three seconds ago after the user changes windows.
    func currentVisualRefreshContext() -> FocusedInputSnapshot? {
        // A window can switch immediately after a poll; capture authorization cannot reuse its age window.
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot
        guard let context = snapshot.context, !context.isSecure,
              SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                globallyEnabled: settingsSnapshot.isGloballyEnabled,
                completionEnabled: settingsSnapshot.isCompletionEnabled,
                temporarilyPaused: settingsSnapshot.isTemporarilyPaused,
                isLowPowerModeActive: lowPowerModeProvider.isLowPowerModeEnabled,
                isLowPowerModeAutoDisableEnabled: settingsSnapshot.isLowPowerModeAutoDisableEnabled,
                disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
                disabledDomains: PerDomainDisableSettings.disabledDomains(),
                suggestInIntegratedTerminals: settingsSnapshot.suggestInIntegratedTerminals,
                inputMonitoringGranted: permissionManager.inputMonitoringGranted,
                screenRecordingGranted: permissionManager.screenRecordingGranted,
                focusSnapshot: snapshot,
                isFastModeEnabled: settingsSnapshot.isFastModeEnabled
              ) else { return nil }
        return context
    }
}
