import Foundation

/// Audio-producing paths share this narrow async interface; native system speech keeps its own
/// delegate queue. Tests replace generation without loading model weights or contacting a server.
nonisolated protocol SpeechAudioGenerating: Sendable {
    func generate(for request: SpeechAudioRequest,
                  receive: @escaping SpeechAudioReceiver) async throws
    func cancel(_ token: SpeechPlaybackToken) async
    func shutdown() async
}

actor SpeechAudioGenerator: SpeechAudioGenerating {
    private let endpoint = SpeechEndpointClient()
    private let local: LocalSpeechRuntime

    init(runtimeEvents: @escaping @Sendable (SpeechRuntimeEvent) async -> Void = { _ in }) {
        local = LocalSpeechRuntime(events: runtimeEvents)
    }

    func generate(for request: SpeechAudioRequest,
                  receive: @escaping SpeechAudioReceiver) async throws {
        switch request.source {
        case .local(let configuration):
            try await local.stream(for: request, configuration: configuration) { try await receive(.pcm($0)) }
        case .endpoint(let configuration, let apiKey):
            let data = try await endpoint.audio(text: request.text, configuration: configuration, apiKey: apiKey)
            try Task.checkCancellation()
            try await receive(.encoded(data))
        }
    }

    func cancel(_ token: SpeechPlaybackToken) async { await local.cancel(token) }
    func shutdown() async { await local.shutdown() }
}
