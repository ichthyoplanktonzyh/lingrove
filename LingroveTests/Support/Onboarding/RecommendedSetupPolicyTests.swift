import Foundation
import Testing
@testable import Lingrove

/// Validate user intent and task compatibility without downloading models or changing real
/// preferences. Download/AX/runtime behavior remains covered at its existing service boundaries.
@MainActor
struct RecommendedSetupPolicyTests {
    @Test func recommendationsUsePinnedTaskCompatibleModelsAndSystemCompletionWhenAvailable() throws {
        for memory in [4, 8, 16, 32] {
            for apple in [false, true] {
                let plan = try #require(RecommendedSetupPolicy.plan(
                    hardware: .init(physicalMemoryBytes: UInt64(memory) * 1_073_741_824), appleAvailable: apple))
                #expect(plan.completionEngine == (apple ? .appleIntelligence : .llamaOpenSource))
                #expect((plan.completionModel == nil) == apple)
                if let completion = plan.completionModel {
                    #expect(LocalModelTaskPolicy.supports(completion.filename, task: .completion))
                    if memory < 16 { #expect(completion.filename == OnboardingTemplate.quick.openSourceModelFilename) }
                }
                #expect(LocalModelTaskPolicy.supports(plan.translationModel.filename, task: .translation))
                #expect(LocalModelTaskPolicy.supports(plan.explanationModel.filename, task: .explanation))
                #expect(plan.translationModel.sha256 != nil)
                #expect(plan.explanationModel.sha256 != nil)
                #expect(plan.explanationModel.filename != plan.translationModel.filename)
            }
        }
    }

    @Test func downloadEstimateIncludesModelsWithoutExactByteMetadata() throws {
        let plan = try #require(RecommendedSetupPolicy.plan(
            hardware: .init(physicalMemoryBytes: 16 * 1_073_741_824), appleAvailable: false))
        let completion = try #require(plan.completionModel)
        #expect(RecommendedSetupPolicy.downloadBytes([completion, plan.translationModel, plan.explanationModel]) > 8_000_000_000)
        #expect(RecommendedSetupPolicy.downloadBytes([]) == 0)
    }

    @Test func setupDoesNotReplaceExistingOrIncompleteExplicitProfiles() throws {
        let suite = "lingrove.test.recommended.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learning = LanguageLearningSettings(defaults: defaults)
        let profile = learning.explanation
        #expect(RecommendedSetupPolicy.needsLearningSelection(profile))
        profile.localModel = "my-model.gguf"
        #expect(!RecommendedSetupPolicy.needsLearningSelection(profile))
        profile.localModel = ""
        profile.backend = .endpoint
        #expect(!RecommendedSetupPolicy.needsLearningSelection(profile))
        profile.backend = .local
        profile.powerSwitchingEnabled = true
        #expect(!RecommendedSetupPolicy.needsLearningSelection(profile))
    }

    @Test func delayedDownloadsCannotUndoManualModelOrEngineChanges() {
        #expect(RecommendedSetupPolicy.canFinishCompletion(expected: nil, current: nil, target: "recommended.gguf",
            engine: .llamaOpenSource, powerSwitching: false))
        #expect(RecommendedSetupPolicy.canFinishCompletion(expected: nil, current: "recommended.gguf", target: "recommended.gguf",
            engine: .llamaOpenSource, powerSwitching: false))
        #expect(!RecommendedSetupPolicy.canFinishCompletion(expected: nil, current: "manual.gguf", target: "recommended.gguf",
            engine: .llamaOpenSource, powerSwitching: false))
        #expect(!RecommendedSetupPolicy.canFinishCompletion(expected: nil, current: nil, target: "recommended.gguf",
            engine: .openAICompatible, powerSwitching: false))
        #expect(!RecommendedSetupPolicy.canFinishCompletion(expected: nil, current: nil, target: "recommended.gguf",
            engine: .llamaOpenSource, powerSwitching: true))
    }

    @Test func featureSetupPreservesLanguagesTriggersKeysAndPrivateContextPreferences() throws {
        let suite = "lingrove.test.recommended.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        let learning = settings.languageLearning
        learning.targetLanguage = .japanese
        learning.expressionAssist.trigger = "!!"
        learning.expressionAssist.keyCode = 42
        settings.setClipboardContextEnabled(false)
        settings.setSurfaceContextEnabled(false)
        settings.pauseSuggestions(for: .indefinitely)
        RecommendedSetupPolicy.enableFeatures(settings)
        #expect(settings.isGloballyEnabled && settings.isCompletionEnabled && !settings.isTemporarilyPaused)
        #expect(learning.translationEnabled && learning.sentencePreviewEnabled)
        #expect(learning.expressionAssist.enabled && learning.selectionTranslationEnabled && learning.selectionIconEnabled)
        #expect(learning.targetLanguage == .japanese)
        #expect(learning.expressionAssist.trigger == "!!" && learning.expressionAssist.keyCode == 42)
        #expect(!settings.isClipboardContextEnabled && !settings.isSurfaceContextEnabled)
        #expect(!learning.screenshotTranslationEnabled && !learning.pointerTranslationEnabled)
    }
}
