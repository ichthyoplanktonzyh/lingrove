import Combine
import Foundation
import Testing
@testable import Lingrove

@MainActor struct LearningGenerationProfileTests {
    @Test func profilesPersistPerModelAndRejectStaleControlWrites() throws {
        let name = "generation-profiles-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningModelSettings(role: .translation, defaults: defaults)
        settings.localModel = "one.gguf"
        settings.template = .hyMT
        let firstID = settings.contextIdentity
        let initial = settings.snapshot
        let value = LearningGenerationProfile(style: .init(register: .formal),
            sampling: .init(temperature: 0.2, seedMode: .fixed, fixedSeed: 7))
        var observed: LearningModelSnapshot?
        let token = settings.changes.sink { observed = settings.snapshot }
        settings.setGenerationProfile(value, expectedIdentity: firstID)
        #expect(observed == settings.snapshot && observed != initial)
        #expect(initial.usesSameRuntime(as: settings.snapshot))
        settings.localModel = "two.gguf"
        #expect(settings.generationProfile == .init())
        settings.setGenerationProfile(value, expectedIdentity: firstID)
        #expect(settings.generationProfile == .init())
        settings.localModel = "one.gguf"
        #expect(settings.generationProfile == value)
        let restored = LearningModelSettings(role: .translation, defaults: defaults)
        #expect(restored.generationProfile == value)
        settings.backend = .endpoint
        settings.endpointModel = "one.gguf"
        #expect(settings.generationProfile == .init())
        #expect(!initial.usesSameRuntime(as: settings.snapshot))
        let explanation = LearningModelSettings(role: .explanation, defaults: defaults)
        explanation.localModel = "one.gguf"
        #expect(explanation.generationProfile == .init())
        token.cancel()
    }
    @Test func automaticRecommendationsWaitForMetadataAndRejectStaleResolution() throws {
        let name = "generation-metadata-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningModelSettings(role: .translation, defaults: defaults)
        settings.localModel = "renamed.gguf"
        let identity = settings.contextIdentity
        #expect(settings.recommendedSampling == nil && settings.translationStyleAvailable == nil)
        settings.setResolvedTemplate(.hyMT, expectedIdentity: identity)
        #expect(settings.recommendedSampling == LearningInstructionSampling.hyMT.values)
        #expect(settings.translationStyleAvailable == true)
        settings.localModel = "another.gguf"
        settings.setResolvedTemplate(.translateGemma, expectedIdentity: identity)
        #expect(settings.recommendedSampling == nil)
        settings.setResolvedTemplate(.translateGemma, expectedIdentity: settings.contextIdentity)
        #expect(settings.translationStyleAvailable == false)
        settings.setGenerationProfile(.init(style: .init(register: .formal)))
        #expect(settings.snapshot.translationStyle.register == .formal,
            "Saved intent stays stable while the request adapter gates unsupported style")
    }

    @Test func dormantCustomTextDoesNotInvalidateNaturalRequests() throws {
        let name = "generation-effective-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningModelSettings(role: .translation, defaults: defaults)
        let before = settings.snapshot
        settings.setGenerationProfile(.init(style: .init(customInstruction: "Remember me")))
        #expect(before == settings.snapshot)
        #expect(settings.generationProfile.style.customInstruction == "Remember me")
        settings.backend = .endpoint
        let endpoint = settings.snapshot
        var profile = settings.generationProfile
        profile.sampling.topK = 16
        profile.sampling.seedMode = .fixed
        settings.setGenerationProfile(profile)
        #expect(endpoint == settings.snapshot)
    }
}
