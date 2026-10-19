import Foundation

/// UI and performance observe the same app-owned local-runtime identity. The PID stays present
/// while stopping, until reaping confirms its resources are gone; a new session gets a new UUID.
nonisolated enum SpeechLocalRuntimePhase: String, Sendable {
    case unloaded, loading, ready, generating, stopping, failed

    var label: String {
        switch self {
        case .unloaded: String(localized: "Not loaded", table: "Learning")
        case .loading: String(localized: "Loading", table: "Learning")
        case .ready: String(localized: "Ready", table: "Learning")
        case .generating: String(localized: "Generating speech…", table: "Learning")
        case .stopping: String(localized: "Unloading", table: "Learning")
        case .failed: String(localized: "Failed", table: "Learning")
        }
    }
}

nonisolated struct SpeechRuntimeSnapshot: Equatable, Sendable {
    var sessionID: UUID?
    var generation: UInt64 = 0
    var phase: SpeechLocalRuntimePhase = .unloaded
    var processID: Int32?
    var modelName = ""
    /// Exact loaded asset names travel with the session, independent of a newer settings choice.
    /// Resource management uses them until the process has actually exited, including idle time.
    var loadedModelFilenames: Set<String> = []
}

/// Only names, identities and timings cross this seam. Native paths, text, reference audio and
/// credentials never enter telemetry. Both the controller and performance sampling use this state.
nonisolated struct SpeechRuntimeEvent: Sendable {
    let snapshot: SpeechRuntimeSnapshot
    let token: SpeechPlaybackToken?
    var sequence: UInt64 = 0
    var modelLoadMs: Int?
    var reason: String?
}
