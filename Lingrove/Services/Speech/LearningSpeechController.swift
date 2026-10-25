import Combine
import Foundation

/// Native system speech starts synchronously and finishes through its delegate. Network/local
/// audio generation uses the separate async SpeechAudioGenerating seam. Each event is tied to the
/// immutable token passed with its utterance, so delayed callbacks cannot mutate newer playback.
@MainActor
protocol SpeechProviding: AnyObject {
    var eventHandler: (@MainActor @Sendable (SpeechProviderEvent) -> Void)? { get set }
    func refreshVoices() throws -> [SpeechVoice]
    func speak(
        _ text: String, voice: SpeechVoice, rateMultiplier: Double, token: SpeechPlaybackToken
    ) throws
    func stop(token: SpeechPlaybackToken)
}

/// Owns one user-triggered utterance and its card-facing state. The app environment creates one
/// controller; previews and details submit explicit targets, and settings changes stop current
/// speech before a new preference can make it stale. Catalog enumeration happens only on demand.
@MainActor
final class LearningSpeechController: ObservableObject {
    let settings: LearningSpeechSettings
    let telemetry: SpeechTelemetry
    @Published private(set) var availableLocalModels: [RuntimeModelOption] = []

    @Published private(set) var voiceCatalog: [SpeechVoice] = []
    @Published private(set) var catalogIsLoaded = false
    @Published private(set) var voiceCatalogError: String?
    @Published private(set) var activeTarget: SpeechTarget?
    @Published private(set) var errorTarget: SpeechTarget?
    @Published private(set) var playbackError: String?
    @Published private(set) var phase: SpeechPlaybackPhase?

    /// Settings alone access downloads. Opening a card never scans the speech-model directory.
    lazy var modelDownloads: ModelDownloadManager = {
        let downloads = ModelDownloadManager(runtimeDirectoryURL: modelDirectoryURL,
            assetCatalog: [SpeechModelCatalog.model, SpeechModelCatalog.decoder], taskAssignments: settings.modelTaskAssignments)
        downloads.onModelDirectoryChanged = { [weak self] in self?.refreshLocalModels() }
        downloads.protectedModelFilenames = { [weak self] in
            guard let self else { return [] }
            // Settings may already point to the next model while the idle helper still holds
            // the previous pair. Protect the session's actual files until reaping clears its PID.
            var protected: Set<String> = [
                URL(fileURLWithPath: self.settings.localModelPath).lastPathComponent,
                URL(fileURLWithPath: self.settings.localProjectionPath).lastPathComponent]
            if self.telemetry.runtime.processID != nil {
                protected.formUnion(self.telemetry.runtime.loadedModelFilenames)
            }
            return protected.filter { !$0.isEmpty }
        }
        return downloads
    }()

    private let provider: any SpeechProviding
    let generator: any SpeechAudioGenerating
    var exportToken: SpeechPlaybackToken?
    var exportRevision: UInt64 = 0
    lazy var systemExporter = SystemSpeechAudioExporter()
    private let audioPlayer = SpeechAudioPlayer()
    private let pcmPlayer: any SpeechPCMPlaying
    private let modelDirectoryURL: URL
    private var audioTask: Task<Void, Never>?
    private var activeToken: SpeechPlaybackToken?
    private var activeRequest: SpeechRequest?
    private var subscriptions = Set<AnyCancellable>()

    init(settings: LearningSpeechSettings, provider: (any SpeechProviding)? = nil,
         generator: (any SpeechAudioGenerating)? = nil, telemetry: SpeechTelemetry? = nil,
         pcmPlayer: (any SpeechPCMPlaying)? = nil, modelDirectoryURL: URL? = nil) {
        self.settings = settings
        self.modelDirectoryURL = modelDirectoryURL ?? SpeechModelCatalog.directoryURL
        self.provider = provider ?? SystemSpeechProvider()
        let telemetry = telemetry ?? SpeechTelemetry()
        self.telemetry = telemetry
        self.generator = generator ?? SpeechAudioGenerator(runtimeEvents: { [weak telemetry] in await telemetry?.receive($0) })
        self.pcmPlayer = pcmPlayer ?? SpeechPCMPlayer()
        self.provider.eventHandler = { [weak self] event in self?.receive(event) }
        audioPlayer.eventHandler = { [weak self] event in self?.receive(event) }
        self.pcmPlayer.eventHandler = { [weak self] event in self?.receive(event) }

        telemetry.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)

        settings.playbackInvalidations.sink { [weak self] in
            self?.exportRevision &+= 1
            self?.stop()
        }.store(in: &subscriptions)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    /// Reads the installed voices only when a settings page or explicit speaker action asks for
    /// them. The controller never polls the catalog on app launch or while the user types.
    func refreshVoices() {
        do {
            voiceCatalog = try provider.refreshVoices()
            voiceCatalogError = voiceCatalog.isEmpty
                ? String(localized: "No system speech voices are available.", table: "Learning")
                : nil
        } catch {
            voiceCatalog = []
            voiceCatalogError = error.localizedDescription
        }
        catalogIsLoaded = true
    }

    func voices(for language: LearningLanguage) -> [SpeechVoice] {
        SpeechVoicePolicy.voices(voiceCatalog, for: language)
    }

    /// A second tap on the same card stops it. Starting another target first retires the previous
    /// operation, then validates language/text and starts one new provider utterance.
    func toggle(_ request: SpeechRequest) {
        guard canStartPlayback(request.target) else { return }
        togglePlayback(request)
    }

    private func togglePlayback(_ request: SpeechRequest) {
        if isPlaying(request.target) {
            stop(target: request.target)
            return
        }

        stop()

        guard request.text.utf8.count <= 4_096, request.text.count <= SpeechTextPolicy.maximumLength else {
            setError(SpeechError.textTooLong.localizedDescription, for: request.target)
            return
        }
        guard let text = SpeechTextPolicy.sanitizedText(request.text) else {
            setError(String(localized: "There is no text to read aloud.", table: "Learning"), for: request.target)
            return
        }
        guard let request = resolvedRequest(request, text: text) else { return }
        if settings.selectedProvider != .system {
            startGeneratedAudio(text, request: request)
            return
        }
        if !catalogIsLoaded { refreshVoices() }

        guard !voiceCatalog.isEmpty else {
            setError(voiceCatalogError
                ?? String(localized: "No system speech voices are available.", table: "Learning"), for: request.target)
            return
        }
        guard let voice = SpeechVoicePolicy.select(
            from: voiceCatalog,
            language: request.language,
            preferredVoiceID: settings.voiceID(for: request.language)
        ) else {
            setError(String(
                localized: "No speech voice is available for this language.",
                table: "Learning"
            ), for: request.target)
            return
        }

        let token = SpeechPlaybackToken()
        telemetry.begin(token, model: voice.name, engine: "system_speech", language: request.language)
        activeToken = token
        activeRequest = request
        activeTarget = request.target
        phase = .preparing
        do {
            try provider.speak(text, voice: voice, rateMultiplier: settings.rateMultiplier, token: token)
        } catch {
            guard activeToken == token else { return }
            telemetry.finish(token, outcome: .failed, errorType: String(reflecting: type(of: error)))
            clearActivePlayback()
            setError(error.localizedDescription, for: request.target)
        }
    }

    /// A prepared Anki recording uses the same playback owner as every card. No synthesis is
    /// repeated for audition, and normal speaker buttons can stop or replace this playback.
    private func canStartPlayback(_ target: SpeechTarget) -> Bool {
        guard exportToken == nil else { setError(SpeechError.operationInProgress.localizedDescription, for: target); return false }
        return true
    }

    func audition(_ audio: SpeechExportAudio, ownerID: UUID, language: LearningLanguage) throws {
        guard exportToken == nil else { throw SpeechError.operationInProgress }
        stop()
        let token = SpeechPlaybackToken()
        let target = SpeechTarget(ownerID: ownerID, itemID: "review.audio")
        activeToken = token; activeTarget = target
        activeRequest = SpeechRequest(target: target, text: "", language: language, languageMode: .fixed)
        telemetry.begin(token, model: "Review audio", engine: "recorded_audio", language: language)
        do { try audioPlayer.play(audio.data, rate: 1, token: token) } catch {
            clearActivePlayback(); telemetry.finish(token, outcome: .failed); throw error
        }
    }

    /// Freeze once, before provider selection or any await. Context stays at this boundary;
    /// generated requests contain only the clicked text and this resolved language.
    private func resolvedRequest(_ request: SpeechRequest, text: String) -> SpeechRequest? {
        let language: LearningLanguage?
        switch request.languageMode {
        case .automatic:
            language = SpeechLanguageResolver.resolve(text: text, hint: request.language, context: request.context)
        case .fixed:
            language = request.language
        }
        guard let language else {
            setError(SpeechError.unrecognizedLanguage.localizedDescription, for: request.target)
            return nil
        }
        return SpeechRequest(target: request.target, text: text, language: language, languageMode: .fixed)
    }

    func isPlaying(_ target: SpeechTarget) -> Bool {
        activeTarget == target
    }

    func isPreparing(_ target: SpeechTarget) -> Bool { activeTarget == target && phase == .preparing }

    var configurationError: String? {
        do {
            switch settings.selectedProvider {
            case .system: break
            case .local: _ = try settings.localConfiguration()
            case .endpoint: _ = try settings.endpointConfiguration()
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func refreshLocalModels() {
        if !settings.localModelPath.isEmpty {
            settings.modelTaskAssignments.record(URL(fileURLWithPath: settings.localModelPath).lastPathComponent, for: .speech)
        }
        let models = modelDownloads.installedModelOptions().filter {
            LocalModelTaskPolicy.isCandidate($0.filename, task: .speech,
                assignedTasks: settings.modelTaskAssignments.tasks(for: $0.filename))
        }
        if availableLocalModels != models { availableLocalModels = models }
    }

    /// A model selection is one synchronous MainActor action. Known packages choose an installed
    /// companion from the model's folder first, then the app folder. Missing companions clear the
    /// previous package's decoder so it cannot silently survive a size switch. Custom imports
    /// retain their explicit decoder because filenames cannot prove arbitrary GGUF compatibility.
    func selectLocalModel(_ path: String) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { settings.setLocalAssets(model: "", projection: ""); return }
        let model = URL(fileURLWithPath: path)
        guard settings.modelTaskAssignments.record(model.lastPathComponent, for: .speech),
              LocalModelTaskPolicy.supports(model.lastPathComponent, task: .speech) else { return }
        let filenames = SpeechModelPairingPolicy.decoderFilenames(for: model.lastPathComponent)
        guard !filenames.isEmpty else { settings.setLocalAssets(model: path, projection: settings.localProjectionPath); return }
        let directories = [model.deletingLastPathComponent(), modelDirectoryURL]
        let decoder = directories.lazy.flatMap { directory in filenames.map { directory.appendingPathComponent($0) } }
            .first { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && FileManager.default.isReadableFile(atPath: $0.path) }
        settings.setLocalAssets(model: path, projection: decoder?.path ?? "")
    }

    private func startGeneratedAudio(_ text: String, request: SpeechRequest) {
        let source: SpeechAudioSource
        do {
            guard let configured = try generatedSource(for: request.language) else { return }
            source = configured
        } catch { setError(error.localizedDescription, for: request.target); return }
        let token = SpeechPlaybackToken()
        switch source {
        case .local(let configuration):
            telemetry.begin(token, model: configuration.modelURL.lastPathComponent, engine: "llama", language: request.language)
        case .endpoint(let configuration, _):
            telemetry.begin(token, model: configuration.endpoint.modelName, engine: "openai_compatible", language: request.language)
        }
        let rate = settings.rateMultiplier
        activeToken = token
        activeTarget = request.target
        activeRequest = request
        phase = .preparing
        let audioRequest = SpeechAudioRequest(token: token, text: text, language: request.language, source: source,
            sampling: settings.generationProfile.sampling)
        let isLocal: Bool
        if case .local = source { isLocal = true } else { isLocal = false }
        if isLocal { pcmPlayer.begin(sampleRate: SpeechLocalConfiguration.outputSampleRate, rate: rate, token: token) }
        audioTask = Task { [weak self] in await self?.generateAudio(audioRequest, rate: rate, isLocal: isLocal) }
    }

    private func generateAudio(_ audioRequest: SpeechAudioRequest, rate: Double, isLocal: Bool) async {
        let token = audioRequest.token
        let target = activeRequest?.target
        do {
            try await generator.generate(for: audioRequest) { [weak self] chunk in
                guard let self else { throw CancellationError() }
                try await self.acceptAudio(chunk, rate: rate, token: token)
            }
            try Task.checkCancellation()
            guard self.activeToken == token else { return }
            self.telemetry.generationCompleted(token)
            if isLocal { try await self.pcmPlayer.endInput(token: token) }
        } catch is CancellationError {
            guard self.activeToken == token else { return }
            self.telemetry.finish(token, outcome: .cancelled)
            self.audioPlayer.stop()
            self.pcmPlayer.stop()
            self.clearActivePlayback()
        } catch {
            guard self.activeToken == token else { return }
            self.telemetry.finish(token, outcome: .failed, errorType: String(reflecting: type(of: error)))
            self.audioPlayer.stop()
            self.pcmPlayer.stop()
            self.clearActivePlayback()
            if let target { self.setError(error.localizedDescription, for: target) }
        }
    }

    private func acceptAudio(_ chunk: SpeechAudioChunk, rate: Double, token: SpeechPlaybackToken) async throws {
        try Task.checkCancellation()
        guard activeToken == token else { throw CancellationError() }
        switch chunk {
        case .encoded(let data):
            telemetry.generated(token, bytes: data.count)
            try audioPlayer.play(data, rate: rate, token: token)
        case .pcm(let pcm):
            telemetry.generated(token, bytes: pcm.data.count)
            try await pcmPlayer.enqueue(pcm, token: token)
        }
    }

    private func generatedSource(for language: LearningLanguage) throws -> SpeechAudioSource? {
        switch settings.selectedProvider {
        case .system: return nil
        case .local:
            guard LocalSpeechLanguage.code(for: language) != nil else { throw SpeechError.unsupportedLanguage }
            return .local(try settings.localConfiguration())
        case .endpoint:
            return .endpoint(try settings.endpointConfiguration(), apiKey: try settings.endpointAPIKey())
        }
    }

    func stop() {
        audioTask?.cancel()
        audioTask = nil
        audioPlayer.stop()
        pcmPlayer.stop()
        clearError()
        guard let token = activeToken else {
            clearActivePlayback()
            return
        }
        // Invalidate before asking AVFoundation to stop; a synchronous delegate callback then
        // cannot clear a newer utterance that starts after this method returns.
        telemetry.finish(token, outcome: .cancelled)
        clearActivePlayback()
        provider.stop(token: token)
        Task { [generator] in await generator.cancel(token) }
    }

    func shutdown() {
        stop()
        pcmPlayer.shutdown()
        Task { [generator] in await generator.shutdown() }
    }

    func stop(ownerID: UUID) {
        if activeTarget?.ownerID == ownerID { stop() }
        if errorTarget?.ownerID == ownerID { clearError() }
    }

    func stop(target: SpeechTarget) {
        if activeTarget == target { stop() }
        if errorTarget == target { clearError() }
    }

    func error(for target: SpeechTarget) -> String? {
        errorTarget == target ? playbackError : nil
    }

    private func receive(_ event: SpeechProviderEvent) {
        guard activeToken == event.token else { return }
        switch event {
        case .prepared(_, let milliseconds):
            telemetry.playbackPrepared(event.token, milliseconds: milliseconds)
        case .started:
            telemetry.playbackStarted(event.token)
            phase = .playing
        case .finished:
            telemetry.finish(event.token, outcome: .completed)
            clearActivePlayback()
        case .cancelled:
            telemetry.finish(event.token, outcome: .cancelled)
            clearActivePlayback()
        case .failed(_, let message):
            telemetry.finish(event.token, outcome: .failed, errorType: "playback_failed")
            let target = activeRequest?.target
            clearActivePlayback()
            audioTask?.cancel()
            audioPlayer.stop()
            pcmPlayer.stop()
            Task { [generator] in await generator.cancel(event.token) }
            if let target { setError(message, for: target) }
        }
    }

    private func setError(_ message: String, for target: SpeechTarget) {
        errorTarget = target
        playbackError = message
    }

    private func clearError() {
        errorTarget = nil
        playbackError = nil
    }

    private func clearActivePlayback() {
        activeToken = nil
        activeRequest = nil
        activeTarget = nil
        phase = nil
    }
}
