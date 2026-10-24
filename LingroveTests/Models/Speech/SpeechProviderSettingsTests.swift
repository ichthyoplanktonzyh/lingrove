import Foundation
import Testing
@testable import Lingrove

@Suite @MainActor struct SpeechProviderSettingsTests {
    @Test func providerProfilesRemainIndependentAcrossRelaunch() throws {
        let name = "SpeechProviderSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = InMemoryOpenAICompatibleCredentialStore()
        let settings = LearningSpeechSettings(defaults: defaults, credentialStore: credentials)
        settings.setEndpointBaseURL(" https://speech.example/v1 ")
        settings.setEndpointModel("voice-model")
        settings.setEndpointVoice("voice-a")
        try settings.saveEndpointAPIKey("secret")
        settings.setLocalModelPath("/tmp/model.gguf")
        settings.setLocalProjectionPath("/tmp/mmproj.gguf")
        settings.setVoiceID("system-voice", for: .english)
        settings.selectProvider(.endpoint)
        settings.selectProvider(.local)
        let restored = LearningSpeechSettings(defaults: defaults, credentialStore: credentials)
        #expect(restored.selectedProvider == .local)
        #expect(restored.endpointBaseURL == "https://speech.example/v1")
        #expect(restored.endpointModel == "voice-model")
        #expect(restored.endpointVoice == "voice-a")
        #expect(restored.localModelPath == "/tmp/model.gguf")
        #expect(restored.localProjectionPath == "/tmp/mmproj.gguf")
        #expect(restored.voiceID(for: .english) == "system-voice")
        #expect(try restored.endpointAPIKey() == "secret")
        #expect(defaults.dictionaryRepresentation().values.allSatisfy { ($0 as? String) != "secret" })
        #expect(try InMemoryOpenAICompatibleCredentialStore().readAPIKey() == nil)
    }

    @Test func rejectsMissingAssetsAndInsecurePublicEndpoint() throws {
        let name = "SpeechProviderSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningSpeechSettings(defaults: defaults, credentialStore: InMemoryOpenAICompatibleCredentialStore())
        #expect(throws: SpeechError.self) { try settings.localConfiguration() }
        settings.setEndpointBaseURL("http://public.example")
        settings.setEndpointModel("tts")
        settings.setEndpointVoice("speaker")
        #expect(throws: OpenAICompatibleEndpointError.self) { try settings.endpointConfiguration() }
    }

    @Test func supportedLocalLanguagesUseNativeCodes() {
        #expect(LocalSpeechLanguage.code(for: .chinese) == "zh")
        #expect(LocalSpeechLanguage.code(for: .traditionalChinese) == "zh")
        #expect(LocalSpeechLanguage.code(for: .english) == "en")
        #expect(LocalSpeechLanguage.code(for: .dutch) == nil)
        #expect(LocalSpeechLanguage.code(for: .hindi) == nil)
        #expect(LocalSpeechLanguage.code(for: .arabic) == nil)
    }
}
