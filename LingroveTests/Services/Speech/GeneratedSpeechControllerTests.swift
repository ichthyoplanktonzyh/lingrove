import Foundation
import Testing
@testable import Lingrove

@Suite @MainActor struct GeneratedSpeechControllerTests {
    @Test func endpointPreparingStateDoesNotEnumerateSystemVoicesAndStopCancels() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let generator = PendingSpeechGenerator()
        let controller = LearningSpeechController(settings: fixture.settings, generator: generator)
        let request = fixture.request()
        controller.toggle(request)
        #expect(controller.isPreparing(request.target))
        #expect(!controller.catalogIsLoaded)
        try await waitForRequest(generator)
        controller.stop(ownerID: request.target.ownerID)
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.activeTarget == nil)
        #expect(await generator.cancelledCount > 0)
    }

    @Test func settingsEditInvalidatesTheFrozenEndpointRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let generator = PendingSpeechGenerator()
        let controller = LearningSpeechController(settings: fixture.settings, generator: generator)
        let request = fixture.request()
        controller.toggle(request)
        try await waitForRequest(generator)
        fixture.settings.setEndpointModel("new-model")
        #expect(controller.activeTarget == nil)
        let captured = try #require(await generator.requests.first)
        if case .endpoint(let configuration, let key) = captured.source {
            #expect(configuration.endpoint.modelName == "original-model")
            #expect(key == "speech-key")
        } else { Issue.record("Expected an endpoint request") }
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.error(for: request.target) == nil)
    }

    @Test func invalidGeneratedAudioShowsOnlyItsTargetError() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let generator = PendingSpeechGenerator()
        let controller = LearningSpeechController(settings: fixture.settings, generator: generator)
        let request = fixture.request()
        controller.toggle(request)
        try await waitForRequest(generator)
        let token = try #require(await generator.requests.first?.token)
        await generator.complete(token)
        for _ in 0..<50 {
            if controller.error(for: request.target) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.activeTarget == nil)
        #expect(controller.error(for: request.target) == SpeechError.invalidAudio.localizedDescription)
        #expect(controller.error(for: fixture.request().target) == nil)
    }

    @Test(arguments: [false, true])
    func generatedProvidersReceiveOnlyClickedTextAndItsResolvedLanguage(local: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        if local { try fixture.useLocal() }
        let generator = PendingSpeechGenerator()
        let controller = LearningSpeechController(settings: fixture.settings, generator: generator)
        let request = SpeechRequest(target: .init(ownerID: UUID(), itemID: "translation"),
            text: "Esta es una frase para escuchar en español.", language: .english,
            context: "Context must not be sent to the provider.")
        controller.toggle(request)
        try await waitForRequest(generator)
        let captured = try #require(await generator.requests.first)
        #expect(captured.language == .spanish)
        #expect(captured.text == request.text)
        #expect(!controller.catalogIsLoaded)
        controller.stop()
    }

    @Test
    func detectedUnsupportedLocalLanguageFailsBeforeLaunchingGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.useLocal()
        let generator = PendingSpeechGenerator()
        let controller = LearningSpeechController(settings: fixture.settings, generator: generator)
        let request = SpeechRequest(target: .init(ownerID: UUID(), itemID: "translation"),
            text: "Dit is een Nederlandse zin over het dagelijks leven.", language: .english)
        controller.toggle(request)
        #expect(controller.error(for: request.target) == SpeechError.unsupportedLanguage.localizedDescription)
        #expect(controller.activeTarget == nil)
    }

    private func waitForRequest(_ generator: PendingSpeechGenerator) async throws {
        for _ in 0..<100 {
            if await !generator.requests.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Speech request did not start")
    }

    @Test func localStartsOnFirstBlockAndCompletionWaitsForAudibleDrain() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.useLocal()
        let generator = PendingSpeechGenerator()
        let player = TestPCMPlayer()
        let controller = LearningSpeechController(settings: fixture.settings, generator: generator, pcmPlayer: player)
        let request = fixture.request()
        controller.toggle(request)
        try await waitForRequest(generator)
        let token = try #require(await generator.requests.first?.token)
        try await generator.emitPCM(token)
        #expect(controller.phase == .playing)
        #expect(!player.inputEnded)
        await generator.finishGeneration(token)
        for _ in 0..<100 {
            if player.inputEnded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.inputEnded)
        #expect(controller.activeTarget == request.target)
        player.finishPlayback(token)
        #expect(controller.activeTarget == nil)
    }

    @Test func cancelledLocalBlocksAndLateCompletionsCannotReachNewPlayback() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.useLocal()
        let generator = PendingSpeechGenerator()
        let player = TestPCMPlayer()
        let controller = LearningSpeechController(settings: fixture.settings, generator: generator, pcmPlayer: player)
        let first = fixture.request()
        controller.toggle(first)
        try await waitForRequest(generator)
        let token = try #require(await generator.requests.first?.token)
        try await generator.emitPCM(token)
        controller.stop()
        let second = fixture.request()
        controller.toggle(second)
        await #expect(throws: CancellationError.self) { try await generator.emitPCM(token) }
        player.finishPlayback(token)
        #expect(controller.activeTarget == second.target)
        #expect(player.chunkCount == 1)
        controller.stop()
    }

    @MainActor private struct Fixture {
        let settings: LearningSpeechSettings
        let defaults: UserDefaults
        let name = "GeneratedSpeechControllerTests.\(UUID().uuidString)"
        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            settings = LearningSpeechSettings(defaults: defaults, credentialStore: InMemoryOpenAICompatibleCredentialStore())
            settings.setEndpointBaseURL("http://127.0.0.1:8000/v1")
            settings.setEndpointModel("original-model")
            settings.setEndpointVoice("voice")
            try settings.saveEndpointAPIKey("speech-key")
            settings.selectProvider(.endpoint)
        }
        func request() -> SpeechRequest {
            .init(target: .init(ownerID: UUID(), itemID: "translation"), text: "Hello.", language: .english)
        }
        func clean() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        }
        func useLocal() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for filename in ["model.gguf", "decoder.gguf"] {
                try Data("GGUFfixture".utf8).write(to: root.appendingPathComponent(filename))
            }
            settings.setLocalModelPath(root.appendingPathComponent("model.gguf").path)
            settings.setLocalProjectionPath(root.appendingPathComponent("decoder.gguf").path)
            settings.selectProvider(.local)
        }
    }
}

private actor PendingSpeechGenerator: SpeechAudioGenerating {
    private(set) var requests: [SpeechAudioRequest] = []
    private(set) var cancelledCount = 0
    private var waiters: [SpeechPlaybackToken: CheckedContinuation<Void, Error>] = [:]
    private var receivers: [SpeechPlaybackToken: SpeechAudioReceiver] = [:]
    func generate(for request: SpeechAudioRequest, receive: @escaping SpeechAudioReceiver) async throws {
        receivers[request.token] = receive
        try Task.checkCancellation()
        requests.append(request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[request.token] = $0 }
        } onCancel: { Task { await self.cancel(request.token) } }
    }
    func cancel(_ token: SpeechPlaybackToken) {
        if let waiter = waiters.removeValue(forKey: token) {
            cancelledCount += 1
            waiter.resume(throwing: CancellationError())
        }
    }
    func complete(_ token: SpeechPlaybackToken) async {
        do {
            try await receivers[token]?(.encoded(Data([1, 2, 3])))
            waiters.removeValue(forKey: token)?.resume()
        } catch { waiters.removeValue(forKey: token)?.resume(throwing: error) }
    }
    func shutdown() {
        let tokens = Array(waiters.keys)
        tokens.forEach { cancel($0) }
    }
    func emitPCM(_ token: SpeechPlaybackToken) async throws {
        let chunk = try SpeechPCMChunk(data: Data(repeating: 0, count: 9_600), sampleRate: 24_000)
        try await receivers[token]?(.pcm(chunk))
    }
    func finishGeneration(_ token: SpeechPlaybackToken) { waiters.removeValue(forKey: token)?.resume() }
}

@MainActor private final class TestPCMPlayer: SpeechPCMPlaying {
    var eventHandler: (@MainActor @Sendable (SpeechProviderEvent) -> Void)?
    var inputEnded = false
    var chunkCount = 0
    func begin(sampleRate: Int, rate: Double, token: SpeechPlaybackToken) { inputEnded = false }
    func enqueue(_ chunk: SpeechPCMChunk, token: SpeechPlaybackToken) async throws {
        chunkCount += 1
        eventHandler?(.started(token))
    }
    func endInput(token: SpeechPlaybackToken) async throws { inputEnded = true }
    func stop() {}
    func shutdown() {}
    func finishPlayback(_ token: SpeechPlaybackToken) { eventHandler?(.finished(token)) }
}
