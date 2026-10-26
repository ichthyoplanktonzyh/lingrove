import Foundation

/// Pure first-run choices over the existing, pinned catalog. The setup controller owns applying
/// them; this policy neither downloads weights nor changes a user's saved model selection.
enum RecommendedSetupPolicy {
    struct Plan {
        let completionEngine: SuggestionEngineKind
        let completionModel: DownloadableRuntimeModel?
        let translationModel: DownloadableRuntimeModel
        let explanationModel: DownloadableRuntimeModel
    }

    static func plan(hardware: HardwareCapability, appleAvailable: Bool) -> Plan? {
        let engine: SuggestionEngineKind = appleAvailable ? .appleIntelligence : .llamaOpenSource
        // A complete setup keeps translation alongside completion. Leave more headroom than the
        // completion-only presets on small Macs; the general model is loaded only on demand.
        let tier: OnboardingTemplate = !appleAvailable && hardware.physicalMemoryGigabytes < 16 ? .quick
            : OnboardingTemplateRecommender.recommendedTemplate(hardware: hardware, engine: engine)
        let completion = OnboardingTemplateRecommender.resolvePlan(for: tier, engine: engine)
        guard let translation = LearningRuntimeCatalog.translationModels.first,
              let explanation = LearningRuntimeCatalog.explanationModels.first(where: {
                  $0.filename == "Qwen3.5-4B-Q4_K_M.gguf"
              }), engine == .appleIntelligence || completion.modelToDownload != nil else { return nil }
        // The smaller general model keeps the default download bounded. Explanation and expression
        // assistance already share this runtime; recommending both must never download two copies.
        return Plan(completionEngine: engine, completionModel: completion.modelToDownload,
            translationModel: translation, explanationModel: explanation)
    }

    static func downloadBytes(_ models: [DownloadableRuntimeModel]) -> Int64 {
        models.reduce(0) { $0 + ($1.expectedSizeBytes ?? Int64($1.approximateSizeInGigabytes * 1_000_000_000)) }
    }

    /// An explicit endpoint or power profile is user intent even when incomplete. Setup must not
    /// silently replace it with a local model; the normal configuration form can finish that work.
    static func needsLearningSelection(_ profile: LearningModelSettings) -> Bool {
        profile.backend == .local && profile.localModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !profile.powerSwitchingEnabled
    }

    static func canFinishCompletion(expected: String?, current: String?, target: String,
                                    engine: SuggestionEngineKind, powerSwitching: Bool) -> Bool {
        engine == .llamaOpenSource && !powerSwitching && (current == expected || current == target)
    }

    /// Apply only the feature switches advertised by the recommendation card. Language, trigger,
    /// shortcut, privacy/context and per-app preferences remain the existing settings' responsibility.
    static func enableFeatures(_ settings: SuggestionSettingsModel) {
        settings.setGloballyEnabled(true)
        settings.clearPause()
        settings.setCompletionEnabled(true)
        settings.languageLearning.translationEnabled = true
        settings.languageLearning.sentencePreviewEnabled = true
        settings.languageLearning.selectionTranslationEnabled = true
        settings.languageLearning.selectionIconEnabled = true
        settings.languageLearning.expressionAssist.enabled = true
    }
}
