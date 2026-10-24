import Combine
import Foundation
import Testing
@testable import Lingrove

@MainActor struct SpeechGenerationProfileTests {
    @Test func legacyReferenceMigratesOnlyToTheOriginalPairAndSamplerEditsRestore() throws {
        let name = "speech-generation-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/one.gguf", forKey: "learningSpeech.localModel")
        defaults.set("/decoder-one.gguf", forKey: "learningSpeech.localProjection")
        defaults.set("/voice.wav", forKey: "learningSpeech.referenceAudio")
        let settings = LearningSpeechSettings(defaults: defaults, credentialStore: InMemoryOpenAICompatibleCredentialStore())
        settings.selectProvider(.local)
        let firstID = settings.parameterIdentity
        settings.setSamplingOverrides(.init(topK: 12, seedMode: .fixed, fixedSeed: 8))
        settings.setLocalAssets(model: "/two.gguf", projection: "/decoder-two.gguf")
        #expect(settings.referenceAudioPath.isEmpty && settings.generationProfile.sampling.isRecommended)
        settings.setSamplingOverrides(.init(topK: 1), expectedIdentity: firstID)
        #expect(settings.generationProfile.sampling.isRecommended)
        settings.setReferenceAudioPath("/two.wav")
        settings.setLocalAssets(model: "/one.gguf", projection: "/decoder-one.gguf")
        #expect(settings.referenceAudioPath == "/voice.wav")
        #expect(settings.generationProfile.sampling.fixedSeed == 8)
        let restored = LearningSpeechSettings(defaults: defaults, credentialStore: InMemoryOpenAICompatibleCredentialStore())
        #expect(restored.generationProfile == settings.generationProfile)
        settings.setLocalProjectionPath("/other.gguf")
        #expect(settings.referenceAudioPath.isEmpty)
    }
    @Test func samplerEditDoesNotInvalidateCurrentPlaybackButVoiceEditDoes() throws {
        let name = "speech-playback-change-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningSpeechSettings(defaults: defaults, credentialStore: InMemoryOpenAICompatibleCredentialStore())
        settings.selectProvider(.local)
        var invalidations = 0
        let token = settings.playbackInvalidations.sink { invalidations += 1 }
        settings.setSamplingOverrides(.init(topK: 12))
        #expect(invalidations == 0)
        settings.setReferenceAudioPath("/voice.wav")
        #expect(invalidations == 1)
        token.cancel()
    }

    @Test func endpointVoiceIsScopedToCanonicalDestinationAndModel() throws {
        let name = "speech-voice-scope-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningSpeechSettings(defaults: defaults, credentialStore: InMemoryOpenAICompatibleCredentialStore())
        settings.selectProvider(.endpoint)
        settings.setEndpointModel("one")
        settings.setEndpointVoice("speaker-one")
        settings.setEndpointModel("two")
        #expect(settings.endpointVoice.isEmpty)
        settings.setEndpointModel("one")
        #expect(settings.endpointVoice == "speaker-one")
        settings.setEndpointBaseURL("http://other.invalid/v1")
        #expect(settings.endpointVoice.isEmpty)
    }
}
