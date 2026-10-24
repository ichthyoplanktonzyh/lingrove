import Foundation
import Testing
@testable import Lingrove

/// Speech shares the bounded history while keeping a separate, content-free measurement path.
/// A fake clock distinguishes time to audio/playback from the duration of the spoken passage.
@Suite @MainActor struct SpeechTelemetryTests {
    @Test func sharedHistoryRecordsSpeechStagesAndWaitUntilPlayback() throws {
        let name = "SpeechTelemetryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PerformanceMetricsStore(userDefaults: defaults)
        var clock: TimeInterval = 10
        var phases: [String] = []
        let telemetry = SpeechTelemetry(metrics: store, trackingEnabled: { true }, now: { clock },
            event: { _, phase, _ in phases.append(phase) })
        let token = SpeechPlaybackToken()
        let session = UUID()
        telemetry.begin(token, model: "Qwen3-TTS.gguf", engine: "llama", language: .english)
        telemetry.receive(.init(snapshot: .init(sessionID: session, phase: .loading, processID: 42, modelName: "Qwen3-TTS.gguf"),
            token: token))
        clock = 10.3
        telemetry.receive(.init(snapshot: .init(sessionID: session, phase: .ready, processID: 42, modelName: "Qwen3-TTS.gguf"),
            token: token, modelLoadMs: 300))
        clock = 10.5
        telemetry.generated(token, bytes: 4_800)
        clock = 10.6
        telemetry.playbackStarted(token)
        clock = 10.7
        telemetry.generated(token, bytes: 4_800)
        clock = 10.8
        telemetry.generationCompleted(token)
        clock = 15
        telemetry.finish(token, outcome: .completed)
        telemetry.finish(token, outcome: .cancelled)
        let entry = try #require(store.entries.first)
        #expect(store.entries.count == 1)
        #expect(entry.source == .speech)
        #expect(entry.outcome == .completed)
        #expect(entry.modelLoadMs == 300)
        #expect(entry.firstOutputMs == 500)
        #expect(entry.displayMs == 600)
        #expect(entry.usableResultMs == 800)
        #expect(phases.filter { $0 == "audio_ready" }.count == 1)
        #expect(entry.latencyMs == 600)
        #expect(phases.contains("runtime_ready"))
        let restored = PerformanceMetricsStore(userDefaults: defaults)
        #expect(restored.entries == store.entries)
    }

    @Test func optOutStillLogsLifecycleAndLateUnloadKeepsRequestCorrelation() throws {
        let name = "SpeechTelemetryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PerformanceMetricsStore(userDefaults: defaults)
        var identifiers: [String] = []
        var fields: [[String: String]] = []
        let telemetry = SpeechTelemetry(metrics: store, event: { context, _, details in
            identifiers.append(context.requestID); fields.append(details)
        })
        let token = SpeechPlaybackToken(), session = UUID()
        telemetry.begin(token, model: "model", engine: "llama", language: .chinese)
        telemetry.finish(token, outcome: .cancelled)
        telemetry.receive(.init(snapshot: .init(sessionID: session, phase: .loading, processID: 42, modelName: "model"), token: token))
        telemetry.receive(.init(snapshot: .init(sessionID: session, phase: .unloaded, modelName: "model"), token: token))
        #expect(store.entries.isEmpty)
        #expect(identifiers.count == 5)
        #expect(Set(identifiers).count == 1)
        #expect(telemetry.runtime.processID == nil)
        #expect(fields.allSatisfy { Set($0.keys).isDisjoint(with: ["text", "audio", "prompt", "api_key", "path", "url"]) })
    }

    @Test func delayedOldSessionCannotReplaceNewPIDAndLateLoadPatchesOnlyExistingHistory() throws {
        let name = "SpeechTelemetryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PerformanceMetricsStore(userDefaults: defaults)
        let telemetry = SpeechTelemetry(metrics: store, trackingEnabled: { true }, event: { _, _, _ in })
        let old = SpeechPlaybackToken(), current = SpeechPlaybackToken()
        let first = UUID(), second = UUID()
        telemetry.begin(old, model: "first", engine: "llama", language: .english)
        telemetry.finish(old, outcome: .completed)
        telemetry.begin(current, model: "second", engine: "llama", language: .english)
        telemetry.receive(.init(snapshot: .init(sessionID: second, generation: 2, phase: .loading, processID: 200,
            modelName: "second"), token: current, sequence: 1))
        telemetry.receive(.init(snapshot: .init(sessionID: first, generation: 1, phase: .loading, processID: 100,
            modelName: "first"), token: old, sequence: 1))
        #expect(telemetry.runtime.processID == 200)
        telemetry.receive(.init(snapshot: .init(sessionID: first, generation: 1, phase: .ready, processID: 100,
            modelName: "first"), token: old, sequence: 2, modelLoadMs: 700))
        #expect(store.entries.first?.modelLoadMs == 700)
        #expect(telemetry.runtime.processID == 200)
        store.clear()
        telemetry.receive(.init(snapshot: .init(sessionID: first, generation: 1, phase: .ready,
            modelName: "first"), token: old, sequence: 3, modelLoadMs: 800))
        #expect(store.entries.isEmpty)
    }

    @Test func cancelledAndFailedRequestsHaveDistinctSharedHistoryOutcomes() throws {
        let name = "SpeechTelemetryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PerformanceMetricsStore(userDefaults: defaults)
        let telemetry = SpeechTelemetry(metrics: store, trackingEnabled: { true }, event: { _, _, _ in })
        for outcome in [ModelRequestOutcome.cancelled, .failed] {
            let token = SpeechPlaybackToken()
            telemetry.begin(token, model: "server-model", engine: "openai_compatible", language: .english)
            telemetry.finish(token, outcome: outcome)
        }
        #expect(store.entries.map(\.outcome) == [.cancelled, .failed])
        #expect(store.entries.allSatisfy { $0.source == .speech && $0.displayMs == nil })
    }
}
