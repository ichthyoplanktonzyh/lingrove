import Combine
import Foundation
import Testing
@testable import Cotabby

/// Isolated preferences and credential stores prove that changing an analysis model cannot
/// redirect translation or autocomplete. No real Keychain or application preferences are used.
@MainActor
struct LearningModelSettingsTests {
    @Test
    func rolesPersistIndependentlyAndSecretsStayOutOfPreferences() throws {
        let name = "cotabby.test.learningProfiles.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let translationKeys = InMemoryOpenAICompatibleCredentialStore()
        let analysisKeys = InMemoryOpenAICompatibleCredentialStore()
        let settings = LanguageLearningSettings(defaults: defaults,
            translationCredentials: translationKeys, analysisCredentials: analysisKeys)
        settings.translation.backend = .endpoint
        settings.translation.baseURL = "https://translator.invalid/v1"
        settings.translation.endpointModel = "translator"
        settings.translation.saveAPIKey("translation-secret")
        let translation = settings.snapshot
        settings.analysisEnabled = true
        settings.analysis.backend = .local
        settings.analysis.localModel = "analyst.gguf"
        settings.analysis.template = .qwen3
        settings.analysis.saveAPIKey("analysis-secret")
        #expect(settings.snapshot == translation)
        #expect(try settings.translation.apiKey() == "translation-secret")
        #expect(try settings.analysis.apiKey() == "analysis-secret")
        #expect(!String(describing: defaults.persistentDomain(forName: name)).contains("secret"))
        let restored = LanguageLearningSettings(defaults: defaults,
            translationCredentials: translationKeys, analysisCredentials: analysisKeys)
        #expect(restored.translation.backend == .endpoint)
        #expect(restored.translation.baseURL == settings.translation.baseURL)
        #expect(restored.translation.endpointModel == "translator")
        #expect(restored.analysis.localModel == "analyst.gguf")
        #expect(restored.analysis.template == .qwen3)
        #expect(restored.analysisEnabled)
        settings.analysis.reset()
        #expect(try settings.translation.apiKey() == "translation-secret")
    }

    @Test
    func oldEndpointMigratesOnceWithoutFollowingCompletionChanges() throws {
        let name = "cotabby.test.learningMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("old-translator", forKey: "learningInstructionModel")
        defaults.set("https://old.invalid/v1", forKey: "cotabbyOpenAICompatibleBaseURL")
        let oldKeys = InMemoryOpenAICompatibleCredentialStore()
        try oldKeys.saveAPIKey("old-secret")
        let composed = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults,
            endpointCredentialStore: oldKeys)
        #expect(try composed.languageLearning.translation.apiKey() == "old-secret")
        #expect(try composed.languageLearning.analysis.apiKey() == nil)
        // The production composition marks migration once. Reset only this isolated test's
        // marker to also exercise the injected profile stores and an explicitly cleared key.
        defaults.removeObject(forKey: "learning.translation.credentialMigrated")
        let translationKeys = InMemoryOpenAICompatibleCredentialStore()
        let analysisKeys = InMemoryOpenAICompatibleCredentialStore()
        let settings = LanguageLearningSettings(defaults: defaults,
            translationCredentials: translationKeys, analysisCredentials: analysisKeys)
        settings.translation.migrateLegacyCredential(from: oldKeys)
        #expect(settings.translation.backend == .endpoint)
        #expect(settings.translation.endpointModel == "old-translator")
        #expect(try settings.translation.apiKey() == "old-secret")
        #expect(try settings.analysis.apiKey() == nil)
        #expect(!settings.analysisEnabled)
        defaults.set("https://new.invalid/v1", forKey: "cotabbyOpenAICompatibleBaseURL")
        settings.translation.saveAPIKey(nil)
        settings.translation.migrateLegacyCredential(from: oldKeys)
        let restored = LanguageLearningSettings(defaults: defaults, translationCredentials: translationKeys)
        #expect(restored.translation.baseURL == "https://old.invalid/v1")
        #expect(try restored.translation.apiKey() == nil)
    }

    @Test
    func powerChoicesPersistPerRoleAndDisablingRestoresManualChoice() throws {
        let name = "cotabby.test.learningPower.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageLearningSettings(defaults: defaults)
        let role = settings.translation
        role.localModel = "manual.gguf"
        role.template = .hyMT
        let analysis = settings.analysis.snapshot
        role.setPowerSwitchingEnabled(true)
        #expect(role.batteryProfile.localModel == "manual.gguf")
        #expect(role.pluggedInProfile.template == .hyMT)
        role.batteryProfile = .local("battery.gguf")
        role.pluggedInProfile = .endpoint("ac-model")
        #expect(role.snapshot.backend == .endpoint)
        #expect(role.snapshot.endpointModel == "ac-model")
        role.updatePowerSource(isPluggedIn: false)
        #expect(role.snapshot.localModel == "battery.gguf")
        #expect(settings.analysis.snapshot == analysis)
        let restored = LearningModelSettings(role: .translation, defaults: defaults)
        #expect(restored.powerSwitchingEnabled)
        #expect(restored.snapshot.endpointModel == "ac-model")
        restored.updatePowerSource(isPluggedIn: false)
        #expect(restored.snapshot.localModel == "battery.gguf")
        role.setPowerSwitchingEnabled(false)
        #expect(role.snapshot.localModel == "manual.gguf")
        #expect(role.snapshot.template == .hyMT)
        #expect(role.referencedLocalModels == ["manual.gguf", "battery.gguf"])
    }

    @Test
    func onlyEffectiveConfigurationChangesInvalidateRequests() throws {
        let name = "cotabby.test.learningEffective.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let learning = LanguageLearningSettings(defaults: defaults)
        let role = learning.translation
        role.localModel = "current.gguf"
        let initial = learning.snapshot
        var changes = 0
        let subscription = role.changes.sink { changes += 1 }
        defer { subscription.cancel() }
        role.baseURL = "https://future.invalid/v1"
        role.endpointModel = "future-model"
        role.saveAPIKey("future-key")
        role.batteryProfile = .local("battery.gguf")
        role.updatePowerSource(isPluggedIn: false)
        #expect(changes == 0)
        #expect(learning.snapshot == initial)
        role.updatePowerSource(isPluggedIn: true)
        role.pluggedInProfile = .local("ac.gguf")
        role.setPowerSwitchingEnabled(true)
        #expect(changes == 1)
        #expect(role.snapshot.localModel == "ac.gguf")
        let acSnapshot = learning.snapshot
        role.batteryProfile = .endpoint("unused-battery")
        role.localModel = "future-manual.gguf"
        #expect(changes == 1)
        #expect(learning.snapshot == acSnapshot)
        role.updatePowerSource(isPluggedIn: false)
        #expect(changes == 2)
        #expect(role.snapshot.endpointModel == "unused-battery")
        #expect(role.snapshot.baseURL == "https://future.invalid/v1")
        role.saveAPIKey("different-key")
        #expect(changes == 3)
        role.saveAPIKey("different-key")
        #expect(changes == 3, "Refreshing with the saved key does not invalidate generation")
    }

    @Test
    func translationContextDefaultsFollowPinnedModelsAndStoredOverrides() throws {
        let name = "cotabby.test.learningContextDefaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let profile = LearningModelSettings(role: .translation, defaults: defaults)
        profile.localModel = "Hy-MT2-1.8B-Q4_K_M.gguf"
        #expect(profile.snapshot.contextWindowTokens == 8_192)

        profile.localModel = "TRANSLATEGEMMA-4B-IT-Q4_K_M.GGUF"
        #expect(profile.snapshot.contextWindowTokens == 4_096)
        let gemmaIdentity = profile.contextIdentity
        profile.setContextWindowTokens(8_192, expectedIdentity: gemmaIdentity)
        #expect(profile.snapshot.contextWindowTokens == 8_192)

        profile.localModel = "Hy-MT2-1.8B-Q4_K_M.gguf"
        #expect(profile.snapshot.contextWindowTokens == 8_192)
        profile.localModel = "TRANSLATEGEMMA-4B-IT-Q4_K_M.GGUF"
        #expect(profile.snapshot.contextWindowTokens == 8_192,
            "An explicit per-model choice takes precedence over the catalog recommendation")

        let restored = LearningModelSettings(role: .translation, defaults: defaults)
        #expect(restored.snapshot.contextWindowTokens == 8_192,
            "The override is recovered with the selected model after settings are recreated")
        restored.setContextWindowTokens(nil, expectedIdentity: restored.contextIdentity)
        #expect(restored.snapshot.contextWindowTokens == 4_096,
            "Resetting only this model's override returns to its catalog recommendation")
    }

    @Test
    func staleContextEditCannotBeAppliedAfterSwitchingModels() throws {
        let name = "cotabby.test.learningContextIdentity.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let profile = LearningModelSettings(role: .translation, defaults: defaults)
        profile.localModel = "Hy-MT2-1.8B-Q4_K_M.gguf"
        let oldIdentity = profile.contextIdentity
        profile.localModel = "translategemma-4b-it-Q4_K_M.gguf"

        profile.setContextWindowTokens(16_384, expectedIdentity: oldIdentity)
        #expect(profile.snapshot.contextWindowTokens == 4_096)
        #expect(profile.contexts.tokens(for: profile.contextIdentity) == nil,
            "A delayed control write from the previous model cannot create a new model override")
    }

    @Test
    func contextDefaultsStayScopedToTranslationLocalModels() throws {
        let name = "cotabby.test.learningContextScope.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let translation = LearningModelSettings(role: .translation, defaults: defaults)
        translation.localModel = "custom-translategemma-4b-it-Q4_K_M.gguf"
        #expect(translation.snapshot.contextWindowTokens == 8_192,
            "A model name containing a pinned name is not an exact catalog match")
        translation.localModel = "TranslateGemma 4B"
        translation.template = .translateGemma
        #expect(translation.snapshot.contextWindowTokens == 8_192,
            "Display and template names do not infer a model-specific budget")
        translation.backend = .endpoint
        translation.endpointModel = "translategemma-4b-it-Q4_K_M.gguf"
        #expect(translation.snapshot.contextWindowTokens == 8_192,
            "An endpoint keeps the existing fallback even when its model field resembles a GGUF filename")

        let analysis = LearningModelSettings(role: .analysis, defaults: defaults)
        analysis.localModel = "translategemma-4b-it-Q4_K_M.gguf"
        #expect(analysis.snapshot.contextWindowTokens == 8_192,
            "Translation recommendations do not change analysis defaults")
    }

    @Test
    func batteryAndPluggedInProfilesResolveTheirOwnContextDefaults() throws {
        let name = "cotabby.test.learningPowerContextDefaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let profile = LearningModelSettings(role: .translation, defaults: defaults)
        profile.localModel = "manual.gguf"
        profile.setPowerSwitchingEnabled(true)
        profile.batteryProfile = .local("Hy-MT2-1.8B-Q4_K_M.gguf")
        profile.pluggedInProfile = .local("translategemma-4b-it-Q4_K_M.gguf")
        #expect(profile.snapshot.contextWindowTokens == 4_096)

        let pluggedInIdentity = profile.contextIdentity
        profile.setContextWindowTokens(16_384, expectedIdentity: pluggedInIdentity)
        profile.updatePowerSource(isPluggedIn: false)
        #expect(profile.snapshot.contextWindowTokens == 8_192)
        profile.updatePowerSource(isPluggedIn: true)
        #expect(profile.snapshot.contextWindowTokens == 16_384,
            "The plugged-in override follows the active profile across power changes")
        profile.setContextWindowTokens(nil, expectedIdentity: pluggedInIdentity)
        #expect(profile.snapshot.contextWindowTokens == 4_096)

        let restored = LearningModelSettings(role: .translation, defaults: defaults)
        #expect(restored.snapshot.localModel == "translategemma-4b-it-Q4_K_M.gguf")
        #expect(restored.snapshot.contextWindowTokens == 4_096)
        restored.updatePowerSource(isPluggedIn: false)
        #expect(restored.snapshot.contextWindowTokens == 8_192)
    }

    @Test
    func specialistDownloadCannotBecomeFallbackAutocomplete() {
        #expect(!LearningRuntimeCatalog.isCompletionCandidate(filename: "Hy-MT2-1.8B-Q4_K_M.gguf"))
        #expect(!LearningRuntimeCatalog.isCompletionCandidate(filename: "Hy-MT2-7B-Q4_K_M.gguf"))
        #expect(!LearningRuntimeCatalog.isCompletionCandidate(filename: "translategemma-4b-it-Q4_K_M.gguf"))
        #expect(!LearningRuntimeCatalog.isCompletionCandidate(filename: "Qwen3.5-4B-Q4_K_M.gguf"))
        #expect(LearningRuntimeCatalog.isCompletionCandidate(filename: "Qwen3.5-2B-Base-Q4_K_M.gguf"))
        #expect(LearningRuntimeCatalog.isCompletionCandidate(filename: "my-custom-model.gguf"))
    }

    @Test
    func translationOnlyTemplateIsNotOfferedForAlignment() {
        #expect(LearningChatTemplate.available(for: .translation).contains(.translateGemma))
        #expect(!LearningChatTemplate.available(for: .analysis).contains(.translateGemma))
        #expect(LearningChatTemplate.available(for: .analysis).contains(.automatic))
    }
}
