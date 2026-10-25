import Combine
import Foundation

/// App-owned speech preferences. The settings page edits this object, and the controller observes
/// its published changes to stop an utterance whose voice or rate no longer matches the choice.
/// Only preferences are persisted; installed voices are discovered lazily by the controller.
@MainActor
final class LearningSpeechSettings: ObservableObject {
    let modelTaskAssignments: LocalModelTaskAssignments
    static let minimumRateMultiplier = 0.5
    static let maximumRateMultiplier = 1.5
    static let defaultRateMultiplier = 1.0

    private static let rateKey = "learningSpeech.rateMultiplier"
    private static let voiceIDsKey = "learningSpeech.voiceIDs"

    private var parameters: ModelParameterSettings<SpeechGenerationProfile>
    private let defaults: UserDefaults
    private let credentialStore: any OpenAICompatibleCredentialStoring
    private let playbackChanges = PassthroughSubject<Void, Never>()
    /// Only edits that make the active utterance obsolete stop playback. Sampler preferences are
    /// frozen per request and apply on the next click, so UI refreshes cannot evict warm weights.
    var playbackInvalidations: AnyPublisher<Void, Never> { playbackChanges.eraseToAnyPublisher() }

    @Published private(set) var selectedProvider: LearningSpeechProviderKind
    @Published private(set) var localModelPath: String
    @Published private(set) var localProjectionPath: String
    @Published private(set) var referenceAudioPath: String
    @Published private(set) var endpointBaseURL: String
    @Published private(set) var endpointModel: String
    @Published private(set) var endpointVoice: String

    @Published private(set) var rateMultiplier: Double
    @Published private(set) var voiceIDs: [String: String]

    init(defaults: UserDefaults = .standard, credentialStore: (any OpenAICompatibleCredentialStoring)? = nil) {
        modelTaskAssignments = LocalModelTaskAssignments(defaults: defaults)
        self.defaults = defaults
        parameters = ModelParameterSettings(key: "learningSpeech.parameters.v1", defaults: defaults)
        self.credentialStore = credentialStore ?? KeychainOpenAICompatibleCredentialStore(namespace: "learning-speech-endpoint")
        selectedProvider = LearningSpeechProviderKind(rawValue: defaults.string(forKey: "learningSpeech.provider") ?? "") ?? .system
        localModelPath = defaults.string(forKey: "learningSpeech.localModel") ?? ""
        localProjectionPath = defaults.string(forKey: "learningSpeech.localProjection") ?? ""
        referenceAudioPath = defaults.string(forKey: "learningSpeech.referenceAudio") ?? ""
        endpointBaseURL = defaults.string(forKey: "learningSpeech.endpointURL") ?? "http://127.0.0.1:8000/v1"
        endpointModel = defaults.string(forKey: "learningSpeech.endpointModel") ?? ""
        endpointVoice = defaults.string(forKey: "learningSpeech.endpointVoice") ?? ""
        let storedRate = defaults.object(forKey: Self.rateKey) as? Double ?? Self.defaultRateMultiplier
        rateMultiplier = Self.clampRate(storedRate)
        voiceIDs = defaults.dictionary(forKey: Self.voiceIDsKey)?.compactMapValues { $0 as? String } ?? [:]
        // Migrate only the currently configured legacy destination. A new model never inherits
        // another model's reference voice or endpoint speaker, even on its first selection.
        if !localModelPath.isEmpty, parameters.profile(for: localIdentity) == nil {
            parameters.set(.init(referenceAudioPath: referenceAudioPath), for: localIdentity)
        }
        if !endpointModel.isEmpty, parameters.profile(for: endpointIdentity) == nil {
            parameters.set(.init(endpointVoice: endpointVoice), for: endpointIdentity)
        }
    }

    func selectProvider(_ value: LearningSpeechProviderKind) {
        guard selectedProvider != value else { return }
        playbackChanges.send(())
        selectedProvider = value
        defaults.set(value.rawValue, forKey: "learningSpeech.provider")
    }

    /// Pair changes are one transaction so automatic decoder selection does not create an
    /// intermediate model/decoder profile. The controller chooses the pair; this owner persists it.
    func setLocalAssets(model: String, projection: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let projection = projection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard localModelPath != model || localProjectionPath != projection else { return }
        setPath(model, key: "localModel", current: &localModelPath)
        setPath(projection, key: "localProjection", current: &localProjectionPath)
        let reference = parameters.profile(for: localIdentity)?.referenceAudioPath ?? ""
        setPath(reference, key: "referenceAudio", current: &referenceAudioPath)
    }
    func setLocalModelPath(_ value: String) { setLocalAssets(model: value, projection: localProjectionPath) }
    func setLocalProjectionPath(_ value: String) { setLocalAssets(model: localModelPath, projection: value) }
    func setReferenceAudioPath(_ value: String) {
        setPath(value, key: "referenceAudio", current: &referenceAudioPath)
        var profile = parameters.profile(for: localIdentity) ?? .init()
        profile.referenceAudioPath = referenceAudioPath
        parameters.set(profile, for: localIdentity)
    }
    func setEndpointBaseURL(_ value: String) {
        setPath(value, key: "endpointURL", current: &endpointBaseURL)
        restoreEndpointVoice()
    }
    func setEndpointModel(_ value: String) {
        setPath(value, key: "endpointModel", current: &endpointModel)
        restoreEndpointVoice()
    }
    func setEndpointVoice(_ value: String) {
        setPath(value, key: "endpointVoice", current: &endpointVoice)
        var profile = parameters.profile(for: endpointIdentity) ?? .init()
        profile.endpointVoice = endpointVoice
        parameters.set(profile, for: endpointIdentity)
    }
    private func restoreEndpointVoice() {
        setPath(parameters.profile(for: endpointIdentity)?.endpointVoice ?? "", key: "endpointVoice", current: &endpointVoice)
    }

    private var localIdentity: String {
        // The decoder is part of the speech model contract, unlike request-level sampler values.
        ModelContextBudget.identity(backend: "speech-local", model: localModelPath,
            mode: localProjectionPath)
    }
    private var endpointIdentity: String {
        ModelContextBudget.identity(backend: "speech-endpoint", model: endpointModel,
            baseURL: endpointBaseURL)
    }
    var parameterIdentity: String { selectedProvider == .local ? localIdentity : endpointIdentity }
    var generationProfile: SpeechGenerationProfile { parameters.profile(for: parameterIdentity) ?? .init() }
    func setSamplingOverrides(_ value: ModelSamplingOverrides, expectedIdentity: String? = nil) {
        guard selectedProvider == .local else { return }
        if let expectedIdentity, expectedIdentity != parameterIdentity { return }
        var profile = generationProfile
        profile.sampling = value.normalized
        if parameters.set(profile, for: parameterIdentity) { objectWillChange.send() }
    }

    func endpointAPIKey() throws -> String? { try credentialStore.readAPIKey() }

    func saveEndpointAPIKey(_ value: String?) throws {
        try credentialStore.saveAPIKey(value)
        playbackChanges.send(())
        objectWillChange.send()
    }

    func localConfiguration() throws -> SpeechLocalConfiguration {
        let model = URL(fileURLWithPath: localModelPath)
        let projection = URL(fileURLWithPath: localProjectionPath)
        // A decoder in the model slot is still a missing main model. Preserve that actionable
        // error before checking whether an otherwise selectable file belongs to another task.
        guard !localModelPath.isEmpty, !localProjectionPath.isEmpty,
              !SpeechModelPairingPolicy.isKnownDecoder(model.lastPathComponent) else { throw SpeechError.missingLocalAssets }
        guard LocalModelTaskPolicy.supports(model.lastPathComponent, task: .speech) else {
            throw SpeechError.incompatibleLocalModel
        }
        guard model.pathExtension.lowercased() == "gguf", projection.pathExtension.lowercased() == "gguf",
              model.standardizedFileURL != projection.standardizedFileURL,
              FileManager.default.isReadableFile(atPath: model.path),
              FileManager.default.isReadableFile(atPath: projection.path) else { throw SpeechError.missingLocalAssets }
        guard !SpeechModelPairingPolicy.isKnownMismatch(model: model.lastPathComponent, decoder: projection.lastPathComponent) else {
            throw SpeechError.mismatchedLocalAssets
        }
        let reference = referenceAudioPath.isEmpty ? nil : URL(fileURLWithPath: referenceAudioPath)
        if let reference {
            guard ["wav", "mp3"].contains(reference.pathExtension.lowercased()),
                  FileManager.default.isReadableFile(atPath: reference.path),
                  let size = try? reference.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 10 * 1_024 * 1_024 else { throw SpeechError.invalidReferenceAudio }
        }
        return .init(modelURL: model, projectionURL: projection, referenceAudioURL: reference)
    }

    func endpointConfiguration() throws -> SpeechEndpointConfiguration {
        guard !endpointModel.isEmpty, !endpointVoice.isEmpty,
              endpointModel.utf8.count <= 256, endpointVoice.utf8.count <= 256 else {
            throw SpeechError.incompleteConfiguration
        }
        return try .init(endpoint: OpenAICompatibleEndpointConfiguration(
            baseURLString: endpointBaseURL, modelName: endpointModel, apiMode: .chatCompletions), voice: endpointVoice)
    }

    private func setPath(_ value: String, key: String, current: inout String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != normalized else { return }
        playbackChanges.send(())
        current = normalized
        defaults.set(normalized, forKey: "learningSpeech.\(key)")
    }

    func voiceID(for language: LearningLanguage) -> String? {
        voiceIDs[language.rawValue]
    }

    /// Stores a chosen voice id without requiring it to remain installed forever. The selector
    /// safely falls back to another voice for this language if the saved id disappears.
    func setVoiceID(_ voiceID: String?, for language: LearningLanguage) {
        let normalized = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = normalized?.isEmpty == true ? nil : normalized
        guard voiceIDs[language.rawValue] != replacement else { return }

        playbackChanges.send(())
        if let replacement {
            voiceIDs[language.rawValue] = replacement
        } else {
            voiceIDs[language.rawValue] = nil
        }
        defaults.set(voiceIDs, forKey: Self.voiceIDsKey)
    }

    /// Sliders and imported defaults share one clamp so malformed values cannot reach the
    /// synthesizer. Non-finite values reset to the normal speaking rate.
    func setRateMultiplier(_ value: Double) {
        let clamped = Self.clampRate(value)
        guard rateMultiplier != clamped else { return }
        playbackChanges.send(())
        rateMultiplier = clamped
        defaults.set(clamped, forKey: Self.rateKey)
    }

    private static func clampRate(_ value: Double) -> Double {
        guard value.isFinite else { return defaultRateMultiplier }
        return min(max(value, minimumRateMultiplier), maximumRateMultiplier)
    }
}
