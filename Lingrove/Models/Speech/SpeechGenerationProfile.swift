import Foundation

/// Speech generation preferences follow one provider/model, while global playback rate and
/// per-language system voices retain their existing owners. Reference audio is a voice identity
/// input, not a style instruction. Its optional value supports one-time legacy migration.
nonisolated struct SpeechGenerationProfile: Codable, Equatable, Sendable {
    var sampling = ModelSamplingOverrides()
    var referenceAudioPath: String?
    var endpointVoice: String?
}
