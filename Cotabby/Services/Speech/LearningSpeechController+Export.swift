import AVFoundation
import Foundation

extension LearningSpeechController: SpeechExporting {
    var exportConfigurationID: String {
        let identity = [String(exportRevision), settings.selectedProvider.rawValue, settings.localModelPath,
            settings.localProjectionPath, settings.referenceAudioPath, settings.endpointBaseURL,
            settings.endpointModel, settings.endpointVoice] + settings.voiceIDs.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SpeechExportPolicy.digest((try? encoder.encode(identity)) ?? Data()) +
            SpeechExportPolicy.digest((try? encoder.encode(settings.generationProfile)) ?? Data())
    }

    /// Called only after a user enables review audio or requests an audition. Detect language
    /// locally, then freeze the selected provider and voice once; context never leaves this seam.
    func exportRequest(text: String, language: LearningLanguage, context: String? = nil) throws -> SpeechExportRequest {
        guard text.utf8.count <= 4_096, text.count <= SpeechTextPolicy.maximumLength else { throw SpeechError.textTooLong }
        guard let cleaned = SpeechTextPolicy.sanitizedText(text),
              let resolved = SpeechLanguageResolver.resolve(text: cleaned, hint: language, context: context) else {
            throw SpeechError.unrecognizedLanguage
        }
        let source: SpeechExportRequest.Source
        var identity = ["pcm16-v1", cleaned, resolved.rawValue, settings.selectedProvider.rawValue]
        switch settings.selectedProvider {
        case .system:
            if !catalogIsLoaded { refreshVoices() }
            guard let voice = SpeechVoicePolicy.select(from: voiceCatalog, language: resolved,
                preferredVoiceID: settings.voiceID(for: resolved)) else { throw SpeechError.unsupportedLanguage }
            identity += [voice.id]
            source = .system(voiceID: voice.id)
        case .local:
            guard LocalSpeechLanguage.code(for: resolved) != nil else { throw SpeechError.unsupportedLanguage }
            let configuration = try settings.localConfiguration()
            identity += [configuration.modelURL.path, configuration.projectionURL.path, configuration.referenceAudioURL?.path ?? ""]
            source = .generated(.local(configuration), settings.generationProfile.sampling)
        case .endpoint:
            let configuration = try settings.endpointConfiguration()
            identity += [settings.endpointBaseURL, configuration.endpoint.modelName, configuration.voice]
            source = .generated(.endpoint(configuration, apiKey: try settings.endpointAPIKey()), .init())
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let profile = try encoder.encode(settings.generationProfile)
        let fingerprint = SpeechExportPolicy.digest(try encoder.encode(identity) + profile)
        return .init(text: cleaned, language: resolved, fingerprint: fingerprint, source: source)
    }

    /// Export borrows the existing model generator, so it never creates a second warm native
    /// process. A user playback takes precedence; starting export while speech is active fails
    /// visibly instead of stopping that unrelated utterance. Cancellation belongs to the caller.
    func exportAudio(_ request: SpeechExportRequest) async throws -> SpeechExportAudio {
        guard activeTarget == nil, exportToken == nil else {
            throw SpeechError.operationInProgress
        }
        exportToken = request.token
        let model: String, engine: String
        switch request.source {
        case .system(let voice): model = voice; engine = "system_speech"
        case .generated(.local(let config), _): model = config.modelURL.lastPathComponent; engine = "llama"
        case .generated(.endpoint(let config, _), _): model = config.endpoint.modelName; engine = "openai_compatible"
        }
        telemetry.begin(request.token, model: model, engine: engine, language: request.language)
        defer { if exportToken == request.token { exportToken = nil } }
        do {
            let audio: SpeechExportAudio
            switch request.source {
            case .system(let voice): audio = try await systemExporter.audio(text: request.text, voiceID: voice)
            case .generated(let source, let sampling):
                let collector = SpeechExportBuffer()
                let generation = SpeechAudioRequest(token: request.token, text: request.text, language: request.language,
                    source: source, sampling: sampling)
                try await generator.generate(for: generation) { try await collector.append($0) }
                audio = try await collector.finish()
            }
            try Task.checkCancellation()
            guard exportToken == request.token else { throw CancellationError() }
            let decoded = try AVAudioPlayer(data: audio.data)
            guard decoded.duration > 0, decoded.duration <= 90, decoded.duration.isFinite else { throw SpeechError.invalidAudio }
            telemetry.generated(request.token, bytes: audio.data.count)
            telemetry.generationCompleted(request.token); telemetry.finish(request.token, outcome: .completed)
            return audio
        } catch {
            telemetry.finish(request.token, outcome: error is CancellationError ? .cancelled : .failed,
                errorType: error is CancellationError ? nil : String(reflecting: type(of: error)))
            await generator.cancel(request.token)
            throw error
        }
    }
}
