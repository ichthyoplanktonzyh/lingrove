import Combine
import Foundation
import Logging

/// The app owns one content-free speech observer beside the existing request metrics store.
/// It records all providers in the shared opt-in history, publishes local-runtime state, and joins
/// generation/playback/unload logs by request ID. It never uses the prompt/audio debug sink.
@MainActor
final class SpeechTelemetry: ObservableObject {
    private struct Measurement {
        let context: LearningRequestContext
        let timestamp: Date
        let startedAt: TimeInterval
        var loadMs: Int?
        var audioReadyMs: Int?
        var playbackMs: Int?
        var generationMs: Int?
        var audioBytes = 0
    }

    @Published private(set) var runtime = SpeechRuntimeSnapshot()
    private let metrics: PerformanceMetricsStore?
    private let trackingEnabled: () -> Bool
    private let now: () -> TimeInterval
    private let event: (LearningRequestContext, String, [String: String]) -> Void
    private var active: [SpeechPlaybackToken: Measurement] = [:]
    private var runtimeSequence: UInt64 = 0
    private var runtimeContext: LearningRequestContext?
    private var recentContexts: [SpeechPlaybackToken: LearningRequestContext] = [:]
    private var recentEntries: [SpeechPlaybackToken: UUID] = [:]
    private var recentTokens: [SpeechPlaybackToken] = []

    init(metrics: PerformanceMetricsStore? = nil, trackingEnabled: @escaping () -> Bool = { false },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         event: @escaping (LearningRequestContext, String, [String: String]) -> Void = {
             CotabbyLogger.speech.info("Speech \($1)", metadata: LearningRequestLog.metadata($0, phase: $1, details: $2))
         }) {
        self.metrics = metrics
        self.trackingEnabled = trackingEnabled
        self.now = now
        self.event = event
    }

    nonisolated deinit {}

    func begin(_ token: SpeechPlaybackToken, model: String, engine: String, language: LearningLanguage) {
        let context = LearningRequestContext(requestID: RequestID.generate(), operationID: RequestID.generate(),
            source: .speech, modelName: model, engine: engine)
        active[token] = Measurement(context: context, timestamp: Date(), startedAt: now())
        event(context, "started", ["language": language.rawValue])
        event(context, "generation_started", [:])
    }

    func generated(_ token: SpeechPlaybackToken, bytes: Int) {
        guard var measurement = active[token] else { return }
        let first = measurement.audioReadyMs == nil
        if first { measurement.audioReadyMs = elapsed(measurement) }
        measurement.audioBytes += bytes
        active[token] = measurement
        if first {
            event(measurement.context, "audio_ready", ["elapsed_ms": String(elapsed(measurement)), "audio_bytes": String(bytes)])
        }
    }

    func generationCompleted(_ token: SpeechPlaybackToken) {
        guard var measurement = active[token], measurement.generationMs == nil else { return }
        measurement.generationMs = elapsed(measurement)
        active[token] = measurement
        event(measurement.context, "generation_completed",
            ["elapsed_ms": String(elapsed(measurement)), "audio_bytes": String(measurement.audioBytes)])
    }

    func playbackStarted(_ token: SpeechPlaybackToken) {
        guard var measurement = active[token], measurement.playbackMs == nil else { return }
        measurement.playbackMs = elapsed(measurement)
        active[token] = measurement
        event(measurement.context, "playback_started", ["elapsed_ms": String(elapsed(measurement))])
    }

    func playbackPrepared(_ token: SpeechPlaybackToken, milliseconds: Int) {
        guard let measurement = active[token] else { return }
        event(measurement.context, "playback_prepared", ["preparation_ms": String(milliseconds),
            "elapsed_ms": String(elapsed(measurement))])
    }

    func finish(_ token: SpeechPlaybackToken, outcome: ModelRequestOutcome, errorType: String? = nil) {
        guard let measurement = active.removeValue(forKey: token) else { return }
        recentContexts[token] = measurement.context
        recentTokens.append(token)
        if recentTokens.count > 16 {
            let retired = recentTokens.removeFirst()
            recentContexts.removeValue(forKey: retired)
            recentEntries.removeValue(forKey: retired)
        }
        var details = ["elapsed_ms": String(elapsed(measurement)), "outcome": outcome.rawValue]
        if let errorType { details["error_type"] = errorType }
        event(measurement.context, "finished", details)
        guard trackingEnabled(), let metrics else { return }
        // Chart the wait for playable audio, not the duration of the spoken passage. A stop while
        // preparing uses the elapsed wait. Playback duration remains a lifecycle event in logs.
        recentEntries[token] = metrics.record(modelName: measurement.context.modelName,
            latencyMs: measurement.playbackMs ?? elapsed(measurement), timestamp: measurement.timestamp,
            source: .speech, outcome: outcome, requestID: measurement.context.requestID,
            modelLoadMs: measurement.loadMs, firstOutputMs: measurement.audioReadyMs,
            usableResultMs: measurement.generationMs, displayMs: measurement.playbackMs)
    }

    func receive(_ event: SpeechRuntimeEvent) {
        let context = event.token.flatMap { active[$0]?.context ?? recentContexts[$0] }
            ?? (event.snapshot.sessionID == runtime.sessionID ? runtimeContext : nil)
        recordLoad(event)
        if acceptRuntime(event) {
            if runtime != event.snapshot { runtime = event.snapshot }
            runtimeContext = context
        }
        if let context { self.event(context, "runtime_" + event.snapshot.phase.rawValue, runtimeDetails(event)) }
    }

    private func recordLoad(_ event: SpeechRuntimeEvent) {
        guard let token = event.token, let duration = event.modelLoadMs else { return }
        if var measurement = active[token] {
            measurement.loadMs = duration
            active[token] = measurement
        } else if trackingEnabled(), let entryID = recentEntries[token] {
            metrics?.recordLoad(entryID: entryID, elapsedMs: duration)
        }
    }

    private func acceptRuntime(_ event: SpeechRuntimeEvent) -> Bool {
        let incoming = event.snapshot
        guard incoming.generation >= runtime.generation else { return false }
        guard incoming.phase == .loading || incoming.sessionID == runtime.sessionID else { return false }
        if incoming.sessionID != runtime.sessionID { runtimeSequence = 0 }
        guard event.sequence == 0 || event.sequence > runtimeSequence else { return false }
        runtimeSequence = event.sequence
        return true
    }

    private func runtimeDetails(_ event: SpeechRuntimeEvent) -> [String: String] {
        var details: [String: String] = [:]
        if let pid = event.snapshot.processID { details["helper_pid"] = String(pid) }
        if let duration = event.modelLoadMs { details["model_load_ms"] = String(duration) }
        if let reason = event.reason { details["reason"] = reason }
        return details
    }

    private func elapsed(_ measurement: Measurement) -> Int {
        max(0, Int(((now() - measurement.startedAt) * 1_000).rounded()))
    }
}
