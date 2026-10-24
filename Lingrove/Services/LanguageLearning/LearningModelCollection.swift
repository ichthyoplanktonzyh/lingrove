import Combine
import Foundation

/// The app graph owns the task controllers and this policy coordinator once. It borrows existing
/// power/global-pause monitors, keeps translation warm when eligible, and loads explanation on demand.
/// None of these decisions writes completion's selection or shares its native cache.
@MainActor
final class LearningModelCollection {
    let translation: LearningModelController
    let explanation: LearningModelController
    let explainer: LearningExplanationService
    let explanationPreview: LearningExplanationSession
    let expressionAssist: ExpressionAssistService
    private let settings: LanguageLearningSettings
    private weak var appSettings: SuggestionSettingsModel?
    private weak var lowPower: (any SuggestionLowPowerModeProviding)?
    private var subscriptions = Set<AnyCancellable>()
    private var policyWork: Task<Void, Never>?

    init(settings: LanguageLearningSettings, client: OpenAICompatibleAPIClient,
         powerSource: PowerSourceMonitor? = nil, appSettings: SuggestionSettingsModel? = nil,
         lowPower: (any SuggestionLowPowerModeProviding)? = nil, telemetry: LearningRequestTelemetry? = nil) {
        self.settings = settings; self.appSettings = appSettings; self.lowPower = lowPower
        translation = LearningModelController(profile: settings.translation, client: client)
        explanation = LearningModelController(profile: settings.explanation, client: client)
        expressionAssist = ExpressionAssistService(model: explanation, telemetry: telemetry ?? LearningRequestTelemetry())
        explainer = LearningExplanationService(settings: settings, model: explanation, telemetry: telemetry ?? LearningRequestTelemetry())
        explanationPreview = LearningExplanationSession(service: explainer)
        translation.generationEligibility = { [weak self] in self?.isEnabled(.translation) == true }
        translation.warmupEligibility = { [weak self] in self?.desiredResidency(.translation) == .warm }
        explanation.generationEligibility = { [weak self] in self?.isEnabled(.explanation) == true }
        explanation.warmupEligibility = { false }
        powerSource?.$isPluggedIn.sink { [weak settings] pluggedIn in
            settings?.translation.updatePowerSource(isPluggedIn: pluggedIn)
            settings?.explanation.updatePowerSource(isPluggedIn: pluggedIn)
        }.store(in: &subscriptions)
        var changes = [settings.translation.changes, settings.explanation.changes,
            settings.$translationEnabled.map { _ in () }.eraseToAnyPublisher()]
        if let appSettings {
            changes += [appSettings.$isGloballyEnabled.map { _ in () }.eraseToAnyPublisher(),
                appSettings.$pauseState.map { _ in () }.eraseToAnyPublisher(),
                appSettings.$isLowPowerModeAutoDisableEnabled.map { _ in () }.eraseToAnyPublisher()]
        }
        if let lowPower { changes += [lowPower.lowPowerModeChanges.map { _ in () }.eraseToAnyPublisher()] }
        Publishers.MergeMany(changes).sink { [weak self] in self?.schedulePolicyUpdate() }.store(in: &subscriptions)
        reconcileResources()
    }

    private func schedulePolicyUpdate() {
        policyWork?.cancel()
        // @Published sends before assignment. Coalesce that turn, then read committed settings;
        // this also prevents queued warmups from racing a later disable/power-source switch.
        policyWork = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.reconcileResources()
        }
    }

    private var paused: Bool {
        appSettings?.isTemporarilyPaused == true ||
            (lowPower?.isLowPowerModeEnabled == true && appSettings?.isLowPowerModeAutoDisableEnabled == true)
    }
    private func isEnabled(_ role: LearningModelRole) -> Bool {
        let taskEnabled = role == .explanation || settings.translationEnabled
        return taskEnabled && (appSettings?.isGloballyEnabled ?? true) && !paused
    }
    private func desiredResidency(_ role: LearningModelRole) -> LocalRuntimeResidency {
        let profile = controller(for: role).profile
        return LocalRuntimeResidencyPolicy.residency(usesLocalModel: profile.snapshot.backend == .local,
            enabled: isEnabled(role), paused: paused, keepWarm: role == .translation)
    }
    func reconcileResources() {
        translation.applyResidency(desiredResidency(.translation), generationAllowed: isEnabled(.translation))
        explanation.applyResidency(desiredResidency(.explanation), generationAllowed: isEnabled(.explanation))
    }

    func controller(for role: LearningModelRole) -> LearningModelController {
        switch role {
        case .translation: translation
        case .explanation: explanation
        }
    }
    func refreshModels() { translation.refreshModels(); explanation.refreshModels(); reconcileResources() }
    func shutdownSync() {
        policyWork?.cancel(); policyWork = nil
        translation.shutdownSync(); explanation.shutdownSync()
    }
}
