import Foundation
import Testing
@testable import Lingrove

/// Replays user actions against the production controller while a fake provider records only
/// operation metadata. The tests never synthesize sound or store the learner's text in logs.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LearningSpeechControllerTests {
    @Test
    func catalogIsLazyAndOnlyTheExplicitSpeakerActionLoadsIt() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeSpeechProvider()
        let controller = LearningSpeechController(
            settings: LearningSpeechSettings(defaults: defaults), provider: provider
        )

        #expect(provider.refreshCount == 0)
        controller.refreshVoices()
        #expect(provider.refreshCount == 1)
        #expect(controller.voices(for: .english).count == 1)
    }

    @Test
    func anotherTargetStopsTheOldUtteranceAndLateEventsCannotClearTheNewOne() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeSpeechProvider()
        provider.cancelOnStop = true
        let controller = LearningSpeechController(
            settings: LearningSpeechSettings(defaults: defaults), provider: provider
        )
        let first = request(owner: UUID(), item: "preview", language: .english)
        let second = request(owner: UUID(), item: "detail", language: .spanish)

        controller.toggle(first)
        let firstToken = try #require(provider.starts.first?.token)
        controller.toggle(second)
        let secondToken = try #require(provider.starts.last?.token)

        #expect(provider.stopTokens == [firstToken])
        #expect(controller.isPlaying(second.target))
        provider.send(.finished(firstToken))
        provider.send(.cancelled(firstToken))
        #expect(controller.isPlaying(second.target))
        provider.send(.finished(secondToken))
        #expect(!controller.isPlaying(second.target))
    }

    @Test
    func tappingTheActiveTargetTogglesItOffAndStopsOnlyOnce() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeSpeechProvider()
        let controller = LearningSpeechController(
            settings: LearningSpeechSettings(defaults: defaults), provider: provider
        )
        let request = request(owner: UUID(), item: "word-1", language: .english)

        controller.toggle(request)
        controller.toggle(request)
        controller.toggle(request)

        #expect(provider.starts.count == 2)
        #expect(provider.stopTokens.count == 1)
        #expect(controller.isPlaying(request.target))
    }

    @Test
    func ownerAndTargetStopsAreScoped() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeSpeechProvider()
        let controller = LearningSpeechController(
            settings: LearningSpeechSettings(defaults: defaults), provider: provider
        )
        let owner = UUID()
        let request = request(owner: owner, item: "preview", language: .english)
        controller.toggle(request)
        let token = try #require(provider.starts.last?.token)

        controller.stop(target: .init(ownerID: UUID(), itemID: "preview"))
        #expect(provider.stopTokens.isEmpty)
        controller.stop(ownerID: UUID())
        #expect(provider.stopTokens.isEmpty)
        controller.stop(ownerID: owner)

        #expect(provider.stopTokens == [token])
        #expect(!controller.isPlaying(request.target))
    }

    @Test
    func changingSpeechSettingsStopsTheUtterance() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningSpeechSettings(defaults: defaults)
        let provider = FakeSpeechProvider()
        let controller = LearningSpeechController(settings: settings, provider: provider)
        let request = request(owner: UUID(), item: "preview", language: .english)
        controller.toggle(request)
        let token = try #require(provider.starts.last?.token)

        settings.setRateMultiplier(1.25)

        #expect(provider.stopTokens == [token])
        #expect(!controller.isPlaying(request.target))
    }

    @Test
    func providerAndLanguageFailuresAreVisibleWithoutEnglishFallback() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningSpeechSettings(defaults: defaults)
        let provider = FakeSpeechProvider(voices: [englishVoice])
        let controller = LearningSpeechController(settings: settings, provider: provider)
        let request = request(owner: UUID(), item: "spanish", language: .spanish)

        controller.toggle(request)

        #expect(provider.starts.isEmpty)
        #expect(controller.error(for: request.target) != nil)
        #expect(!controller.isPlaying(request.target))
    }

    @Test
    func catalogFailureIsPublishedAndReturnedForAnExplicitRequest() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeSpeechProvider()
        provider.refreshError = FakeSpeechError.unavailable
        let controller = LearningSpeechController(
            settings: LearningSpeechSettings(defaults: defaults), provider: provider
        )
        let request = request(owner: UUID(), item: "english", language: .english)

        controller.toggle(request)

        #expect(provider.refreshCount == 1)
        #expect(controller.catalogIsLoaded)
        #expect(controller.voiceCatalogError == "Fake speech provider failed.")
        #expect(controller.error(for: request.target) == "Fake speech provider failed.")
        #expect(provider.starts.isEmpty)
    }

    @Test
    func synchronousStartFailureAndLateProviderFailureRemainTargetScoped() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeSpeechProvider()
        let controller = LearningSpeechController(
            settings: LearningSpeechSettings(defaults: defaults), provider: provider
        )
        let first = request(owner: UUID(), item: "first", language: .english)
        provider.speakError = FakeSpeechError.unavailable

        controller.toggle(first)
        #expect(controller.error(for: first.target) == "Fake speech provider failed.")
        #expect(!controller.isPlaying(first.target))

        provider.speakError = nil
        let second = request(owner: UUID(), item: "second", language: .english)
        controller.toggle(second)
        let secondToken = try #require(provider.starts.last?.token)
        provider.send(.failed(secondToken, message: "The system speech service stopped."))

        #expect(controller.error(for: second.target) == "The system speech service stopped.")
        #expect(!controller.isPlaying(second.target))
    }

    @Test
    func dismissingOwnersClearsTheirErrorsWithoutRetainingFailureHistory() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeSpeechProvider()
        provider.speakError = FakeSpeechError.unavailable
        let controller = LearningSpeechController(
            settings: LearningSpeechSettings(defaults: defaults), provider: provider
        )

        for index in 0..<12 {
            let owner = UUID()
            let request = request(owner: owner, item: "item-\(index)", language: .english)
            controller.toggle(request)
            #expect(controller.error(for: request.target) != nil)
            controller.stop(ownerID: owner)
            #expect(controller.error(for: request.target) == nil)
        }

        #expect(controller.errorTarget == nil)
        #expect(controller.playbackError == nil)
    }

    @Test
    func automaticSpeechChoosesTheTextLanguageWhileAuditionsRespectTheExplicitChoice() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeSpeechProvider()
        let controller = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults), provider: provider)
        let automatic = SpeechRequest(target: .init(ownerID: UUID(), itemID: "preview.translation"),
            text: "Please keep me posted on the progress.", language: .spanish)
        controller.toggle(automatic)
        #expect(provider.starts.last?.voice.language == "en-US")
        controller.stop()
        let fixed = SpeechRequest(target: .init(ownerID: UUID(), itemID: "settings.audition"),
            text: automatic.text, language: .spanish, languageMode: .fixed)
        controller.toggle(fixed)
        #expect(provider.starts.last?.voice.language == "es-ES")
        controller.stop()
    }

    @Test
    func wordContextSelectsThePreferredVoiceWithoutSpeakingItsContext() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningSpeechSettings(defaults: defaults)
        settings.setVoiceID("french-preferred", for: .french)
        let provider = FakeSpeechProvider(voices: [englishVoice,
            .init(id: "fr-default", name: "French", language: "fr-FR", quality: .premium),
            .init(id: "french-preferred", name: "Preferred French", language: "fr-FR", quality: .standard)])
        let controller = LearningSpeechController(settings: settings, provider: provider)
        let request = SpeechRequest(target: .init(ownerID: UUID(), itemID: "detail.chat"), text: "chat",
            language: .english, context: "Le chat dort tranquillement dans la maison.")
        controller.toggle(request)
        let start = try #require(provider.starts.last)
        #expect(start.voice.id == "french-preferred")
        #expect(start.text == "chat")
        controller.stop()
    }

    @Test
    func selectingKnownPackagesSwitchesBothFilesWithoutLoadingTheRuntime() throws {
        let (name, defaults) = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let large = "Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf", small = "Qwen3-TTS-12Hz-0.6B-Base.Q4_K_M.gguf"
        let largeDecoder = "mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf"
        let smallDecoder = "Qwen3-TTS-12Hz-0.6B-Base.mmproj-Q8_0.gguf"
        for filename in [large, small, largeDecoder, smallDecoder] {
            try Data("GGUFfixture".utf8).write(to: directory.appendingPathComponent(filename))
        }
        let settings = LearningSpeechSettings(defaults: defaults)
        settings.selectProvider(.local)
        let provider = FakeSpeechProvider()
        let controller = LearningSpeechController(settings: settings, provider: provider, modelDirectoryURL: directory)
        for (model, decoder) in [(small, smallDecoder), (large, largeDecoder), (small, smallDecoder)] {
            controller.selectLocalModel(directory.appendingPathComponent(model).path)
            let configuration = try settings.localConfiguration()
            #expect(configuration.modelURL.lastPathComponent == model)
            #expect(configuration.projectionURL.lastPathComponent == decoder)
        }
        controller.refreshLocalModels()
        #expect(Set(controller.availableLocalModels.map(\.filename)) == Set([small, large]))
        #expect(provider.refreshCount == 0)
        #expect(controller.activeTarget == nil)
        let restored = LearningSpeechSettings(defaults: defaults)
        #expect(restored.localProjectionPath == directory.appendingPathComponent(smallDecoder).path)
        settings.setLocalProjectionPath(directory.appendingPathComponent(largeDecoder).path)
        #expect(throws: SpeechError.self) { try settings.localConfiguration() }
        #expect(controller.configurationError == SpeechError.mismatchedLocalAssets.localizedDescription)
        settings.setLocalModelPath(directory.appendingPathComponent(smallDecoder).path)
        #expect(controller.configurationError == SpeechError.missingLocalAssets.localizedDescription)
    }

    @Test
    func missingKnownCompanionClearsTheOldDecoderAndCustomImportsRemainManual() throws {
        let (name, defaults) = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = LearningSpeechSettings(defaults: defaults)
        settings.setLocalProjectionPath("/explicit/custom-decoder.gguf")
        let controller = LearningSpeechController(settings: settings, modelDirectoryURL: directory)
        controller.selectLocalModel(directory.appendingPathComponent("custom.gguf").path)
        #expect(settings.localProjectionPath == "/explicit/custom-decoder.gguf")
        controller.selectLocalModel(directory.appendingPathComponent("Qwen3-TTS-12Hz-0.6B-Base.Q4_K_M.gguf").path)
        #expect(settings.localProjectionPath.isEmpty)
    }

    @Test
    func modelManagementProtectsSelectedAndResidentPairsAcrossSelectionChanges() throws {
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningSpeechSettings(defaults: defaults)
        settings.setLocalModelPath("/fixtures/first.gguf")
        settings.setLocalProjectionPath("/fixtures/custom-decoder.gguf")
        let telemetry = SpeechTelemetry()
        let controller = LearningSpeechController(settings: settings, provider: FakeSpeechProvider(), telemetry: telemetry)
        #expect(controller.modelDownloads.isModelInUse(filename: "custom-decoder.gguf"))

        let session = UUID()
        telemetry.receive(.init(snapshot: .init(sessionID: session, generation: 1, phase: .loading,
            processID: 123, modelName: "first.gguf", loadedModelFilenames: ["first.gguf", "custom-decoder.gguf"]), token: nil))
        settings.setLocalModelPath("/fixtures/next.gguf")
        settings.setLocalProjectionPath("/fixtures/next-decoder.gguf")
        #expect(controller.modelDownloads.isModelInUse(filename: "first.gguf"))
        #expect(controller.modelDownloads.isModelInUse(filename: "custom-decoder.gguf"))
        #expect(controller.modelDownloads.isModelInUse(filename: "next-decoder.gguf"))

        telemetry.receive(.init(snapshot: .init(sessionID: session, generation: 1, phase: .unloaded,
            modelName: "first.gguf", loadedModelFilenames: ["first.gguf", "custom-decoder.gguf"]), token: nil))
        #expect(!controller.modelDownloads.isModelInUse(filename: "first.gguf"))
        #expect(controller.modelDownloads.isModelInUse(filename: "next-decoder.gguf"))
    }

    private var englishVoice: SpeechVoice {
        .init(id: "en-US", name: "English", language: "en-US", quality: .standard)
    }

    private func request(owner: UUID, item: String, language: LearningLanguage) -> SpeechRequest {
        .init(target: .init(ownerID: owner, itemID: item),
              text: language == .spanish ? "Esta es una frase breve." : "A short phrase.", language: language)
    }

    private func makeDefaults() throws -> (name: String, defaults: UserDefaults) {
        let name = "LearningSpeechControllerTests.\(UUID().uuidString)"
        return (name, try #require(UserDefaults(suiteName: name)))
    }
}

@MainActor
private final class FakeSpeechProvider: SpeechProviding {
    struct Start {
        let text: String
        let voice: SpeechVoice
        let rateMultiplier: Double
        let token: SpeechPlaybackToken
    }

    var eventHandler: (@MainActor @Sendable (SpeechProviderEvent) -> Void)?
    var voices: [SpeechVoice]
    var refreshError: Error?
    var speakError: Error?
    var cancelOnStop = false
    private(set) var refreshCount = 0
    private(set) var starts: [Start] = []
    private(set) var stopTokens: [SpeechPlaybackToken] = []

    init(voices: [SpeechVoice] = [
        .init(id: "en-US", name: "English", language: "en-US", quality: .standard),
        .init(id: "es-ES", name: "Spanish", language: "es-ES", quality: .enhanced)
    ]) {
        self.voices = voices
    }

    func refreshVoices() throws -> [SpeechVoice] {
        refreshCount += 1
        if let refreshError { throw refreshError }
        return voices
    }

    func speak(
        _ text: String, voice: SpeechVoice, rateMultiplier: Double, token: SpeechPlaybackToken
    ) throws {
        if let speakError { throw speakError }
        starts.append(.init(text: text, voice: voice, rateMultiplier: rateMultiplier, token: token))
    }

    func stop(token: SpeechPlaybackToken) {
        stopTokens.append(token)
        if cancelOnStop { eventHandler?(.cancelled(token)) }
    }

    func send(_ event: SpeechProviderEvent) {
        eventHandler?(event)
    }
}

private enum FakeSpeechError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Fake speech provider failed." }
}
