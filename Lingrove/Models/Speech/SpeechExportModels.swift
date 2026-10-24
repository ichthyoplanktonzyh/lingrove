import Foundation

/// Review borrows these explicit actions from the app's speech owner. A fake can exercise media
/// transactions without AVFoundation, network access or loaded model weights.
@MainActor
protocol SpeechExporting: AnyObject {
    var exportConfigurationID: String { get }
    func exportRequest(text: String, language: LearningLanguage, context: String?) throws -> SpeechExportRequest
    func exportAudio(_ request: SpeechExportRequest) async throws -> SpeechExportAudio
    func audition(_ audio: SpeechExportAudio, ownerID: UUID, language: LearningLanguage) throws
    func stop(ownerID: UUID)
}

/// A frozen, action-scoped export shares the existing speech runtime but has no playback target.
/// Credentials live only in this ephemeral source; its persisted fingerprint excludes them.
nonisolated struct SpeechExportRequest: Sendable {
    let token = SpeechPlaybackToken()
    let text: String
    let language: LearningLanguage
    let fingerprint: String
    let source: Source
    nonisolated enum Source: Sendable {
        case system(voiceID: String)
        case generated(SpeechAudioSource, ModelSamplingOverrides)
    }
}

/// Encoded, validated short audio is the only value Review receives from the speech boundary.
nonisolated struct SpeechExportAudio: Sendable {
    let data: Data
    let fileExtension: String
}
