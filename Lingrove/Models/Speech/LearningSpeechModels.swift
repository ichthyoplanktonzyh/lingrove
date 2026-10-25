import Foundation

/// Values that cross the speech settings, controller, and system provider boundaries. Keeping
/// these independent of AVFoundation lets voice selection and card identity stay deterministic.
nonisolated enum LearningSpeechProviderKind: String, CaseIterable, Identifiable, Sendable {
    case system, local, endpoint

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "System speech", table: "Learning")
        case .local: String(localized: "Local model (llama.cpp)", table: "Learning")
        case .endpoint: String(localized: "Endpoint", table: "Learning")
        }
    }
}

/// Frozen inputs cross the async synthesis seam. They are captured only on an explicit click,
/// so a settings edit cannot redirect an already-running request to a different model or server.
nonisolated struct SpeechLocalConfiguration: Equatable, Sendable {
    /// The pinned helper accepts only Qwen3-TTS's 24 kHz codec. Supplying that explicit format
    /// lets playback prepare before PCM arrives; a mismatched stream is rejected, never guessed.
    static let outputSampleRate = 24_000
    let modelURL: URL
    let projectionURL: URL
    let referenceAudioURL: URL?
}

nonisolated struct SpeechEndpointConfiguration: Equatable, Sendable {
    let endpoint: OpenAICompatibleEndpointConfiguration
    let voice: String
}

nonisolated enum SpeechAudioSource: Sendable {
    case local(SpeechLocalConfiguration)
    case endpoint(SpeechEndpointConfiguration, apiKey: String?)
}

nonisolated struct SpeechAudioRequest: Sendable {
    let token: SpeechPlaybackToken
    let text: String
    let language: LearningLanguage
    let source: SpeechAudioSource
    var sampling = ModelSamplingOverrides()
}

nonisolated enum SpeechPlaybackPhase: Equatable, Sendable {
    case preparing, playing
}

/// User-facing failures describe actionable configuration/audio states without exposing request
/// text, server response bodies, credentials, or native diagnostics in the learning card.
nonisolated enum SpeechError: LocalizedError {
    case incompleteConfiguration, missingLocalAssets, mismatchedLocalAssets, unsupportedLanguage
    case unrecognizedLanguage, runtimeUnavailable, operationInProgress, incompatibleLocalModel
    case generationFailed, invalidAudio, invalidReferenceAudio, responseTooLarge, textTooLong, endpointStatus(Int)

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration:
            String(localized: "Choose a speech model and voice in TTS settings first.", table: "Learning")
        case .missingLocalAssets:
            String(localized: "Choose both the Qwen3-TTS model and its matching audio decoder.", table: "Learning")
        case .mismatchedLocalAssets:
            String(localized: "Choose the matching audio decoder for the selected speech model.", table: "Learning")
        case .incompatibleLocalModel:
            String(localized: "This model is not compatible with this task. Choose another model.", table: "Learning")
        case .unsupportedLanguage:
            String(localized: "This local speech model does not support this language.", table: "Learning")
        case .unrecognizedLanguage:
            String(localized: "Speech is not available for the detected language.", table: "Learning")
        case .runtimeUnavailable:
            String(localized: "The local speech runtime is unavailable. Reinstall Lingrove and try again.", table: "Learning")
        case .operationInProgress:
            String(localized: "Stop the current speech operation first.", table: "Vocabulary")
        case .generationFailed:
            String(localized: "Speech generation failed. Check the model or connection and try again.", table: "Learning")
        case .invalidAudio:
            String(localized: "The speech provider returned audio that could not be played.", table: "Learning")
        case .invalidReferenceAudio:
            String(localized: "The reference voice file is unavailable. Choose a readable WAV or MP3 file.", table: "Learning")
        case .responseTooLarge:
            String(localized: "The speech audio exceeded the size limit. Try a shorter passage.", table: "Learning")
        case .textTooLong:
            String(localized: "This passage is too long to read aloud. Choose a shorter passage.", table: "Learning")
        case .endpointStatus(let status):
            String(localized: "The speech server returned HTTP \(status). Check its TTS configuration.", table: "Learning")
        }
    }
}

/// The system catalog's relative voice quality, normalized so policy tests do not depend on
/// AVFoundation enum details. Higher values win only after language and explicit preference.
nonisolated enum SpeechVoiceQuality: Int, Comparable, Sendable {
    case standard = 0
    case enhanced = 1
    case premium = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A snapshot of one installed system voice. `language` retains the voice's BCP-47 identifier,
/// including script and region, so the selector can distinguish Simplified and Traditional Chinese.
nonisolated struct SpeechVoice: Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let language: String
    let quality: SpeechVoiceQuality
    var isSystemPreferred = false
    var isNovelty = false
}

/// Distinguishes equal text in separate previews or dictionary details. Views create targets;
/// the controller owns only the one currently speaking and never retains a presentation object.
nonisolated struct SpeechTarget: Equatable, Hashable, Sendable {
    let ownerID: UUID
    let itemID: String
}

/// Card requests detect language from their text; settings auditions deliberately keep the user's
/// selected language. This is per-action intent, not a second durable speech-language setting.
nonisolated enum SpeechLanguageMode: Equatable, Sendable { case automatic, fixed }

/// An explicit user action carrying a fallback language and optional same-side sentence context.
/// The controller sanitizes text and freezes the resolved language before it reaches any provider.
/// Context assists local language recognition only; it is never spoken or sent to an endpoint.
nonisolated struct SpeechRequest: Equatable, Sendable {
    let target: SpeechTarget
    let text: String
    let language: LearningLanguage
    var context: String?
    var languageMode: SpeechLanguageMode = .automatic
}

/// A unique provider operation id. A stopped utterance may report a delayed delegate callback;
/// matching this token prevents that callback from clearing a newer playback session.
nonisolated struct SpeechPlaybackToken: Equatable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Provider callbacks carry the token attached to the utterance that produced them. The
/// controller compares it with its active token before publishing completion or failure.
nonisolated enum SpeechProviderEvent: Equatable, Sendable {
    case prepared(SpeechPlaybackToken, milliseconds: Int)
    case started(SpeechPlaybackToken)
    case finished(SpeechPlaybackToken)
    case cancelled(SpeechPlaybackToken)
    case failed(SpeechPlaybackToken, message: String)

    var token: SpeechPlaybackToken {
        switch self {
        case .prepared(let token, _), .started(let token), .finished(let token), .cancelled(let token), .failed(let token, _): token
        }
    }
}
