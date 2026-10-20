import AppKit
import Foundation
import Testing
@testable import Cotabby

/// Opt-in, local Release measurements of the production translation service and AppKit panel.
/// Each block owns one native controller: its first request starts without resident weights;
/// later requests reuse that allocation. Isolated settings and synthetic text never touch the
/// user's model selection or editor, and incremental JSON retains every observed trial.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COTABBY_RUN_TRANSLATION_LATENCY"] == "1"))
@MainActor
struct LearningTranslationLatencyEvalTests {
    @Test(.timeLimit(.minutes(10)))
    func reportSpecialistTranslationArrivalAndDisplay() async throws {
        #if DEBUG
        Issue.record("Latency measurements require a Release build")
        return
        #else
        let environment = ProcessInfo.processInfo.environment
        let modelDirectory = URL(fileURLWithPath: try #require(environment["COTABBY_TRANSLATION_LATENCY_MODELS"]))
        let output = URL(fileURLWithPath: try #require(environment["COTABBY_TRANSLATION_LATENCY_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let filenames = ["Hy-MT2-1.8B-Q4_K_M.gguf", "translategemma-4b-it-Q4_K_M.gguf"]
        for filename in filenames {
            #expect(FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(filename).path))
        }
        var report = Report(thermalStateAtStart: ProcessInfo.processInfo.thermalState.rawValue)
        for round in 0..<3 {
            // Reverse every other block to avoid always measuring the larger model second.
            let order = round.isMultiple(of: 2) ? filenames : Array(filenames.reversed())
            for filename in order {
                try await measureBlock(filename: filename, directory: modelDirectory, round: round,
                    output: output, report: &report)
            }
        }
        report.thermalStateAtEnd = ProcessInfo.processInfo.thermalState.rawValue
        try save(report, to: output)
        #expect(report.rows.count == 42)
        #expect(report.rows.allSatisfy { $0.firstOutputMs != nil && $0.usableMs != nil && $0.displayMs != nil })
        #expect(report.rows.allSatisfy { $0.prefixPublications > 0 && !$0.firstPrefix.isEmpty })
        #endif
    }

    /// This graph matches the application's service/controller/telemetry/panel boundaries. Only
    /// model file resolution and UserDefaults storage are injected for isolation. In particular,
    /// no coordinator response cache can turn a repeated fixture into a zero-inference result.
    private func measureBlock(
        filename: String, directory: URL, round: Int, output: URL, report: inout Report
    ) async throws {
        let suite = "io.lingrove.tests.translationLatency.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        settings.setGloballyEnabled(true)
        settings.languageLearning.translationEnabled = true
        settings.languageLearning.sourceLanguages = [.chinese, .english]
        let profile = settings.languageLearning.translation
        profile.backend = .local
        profile.localModel = filename
        let controller = LearningModelController(profile: profile, client: OpenAICompatibleAPIClient(),
            localModelURL: { directory.appendingPathComponent($0) })
        // On-demand avoids a competing automatic warmup for the first measured request. The
        // allocation remains alive throughout this block, just as the app's warm translation role.
        controller.idleReleaseDelay = .seconds(600)
        let metrics = PerformanceMetricsStore(userDefaults: defaults)
        let telemetry = LearningRequestTelemetry(metrics: metrics, trackingEnabled: { true })
        let translator = LearningTranslationService(settings: settings, model: controller, telemetry: telemetry)
        let panel = LearningSentencePanel()
        defer { panel.hide(); controller.shutdownSync() }
        let screen = try #require(NSScreen.main?.visibleFrame)
        let caret = CGRect(x: screen.midX - 160, y: screen.midY, width: 2, height: 18)
        let trials = [("unloaded", Self.fixtures[0])] + Self.fixtures.map { ("resident", $0) }
        for (residency, fixture) in trials {
            panel.hide()
            settings.languageLearning.targetLanguage = fixture.target
            let requestID = "latency_\(UUID().uuidString)"
            let documentID = UUID()
            var prefixPublications = 0
            var firstPrefix = ""
            func show(_ text: String, complete: Bool) {
                panel.show(.init(id: documentID, source: fixture.source, translation: text,
                    sourceLanguage: fixture.language, targetLanguage: fixture.target, caret: caret,
                    isExpanded: false, isGenerating: !complete, message: "", previousTranslation: nil,
                    shortcutLabel: "⌥T", canReplace: complete, replacementShortcutLabel: "⌃⌥T", isTranslating: !complete),
                    expand: {}, dismiss: {}, replace: {})
                telemetry.recordDisplay(source: .translation, requestID: requestID)
            }
            let start = ProcessInfo.processInfo.systemUptime
            let translation = try await LearningRequestTrace.$requestID.withValue(requestID) {
                try await translator.generate(source: fixture.source,
                    task: .translation(source: fixture.language, target: fixture.target), onPartial: { prefix in
                        if firstPrefix.isEmpty { firstPrefix = prefix }
                        prefixPublications += 1
                        show(prefix, complete: false)
                    })
            }
            show(translation, complete: true)
            #expect(panel.isVisible)
            let wallMs = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            let measurement = try #require(metrics.entries.first { $0.requestID == requestID })
            report.rows.append(Row(model: filename, round: round, residency: residency,
                fixture: fixture.id, sourceLanguage: fixture.language.rawValue, targetLanguage: fixture.target.rawValue,
                source: fixture.source, translation: translation, contextTokens: profile.snapshot.contextWindowTokens,
                firstOutputMs: measurement.firstOutputMs, usableMs: measurement.usableResultMs,
                displayMs: measurement.displayMs, wallMs: wallMs,
                prefixPublications: prefixPublications, firstPrefix: firstPrefix,
                thermalState: ProcessInfo.processInfo.thermalState.rawValue))
            try save(report, to: output)
            print("Translation latency: \(filename) round=\(round) \(residency) \(fixture.id) display_ms=\(measurement.displayMs ?? -1)")
        }
    }

    private func save(_ report: Report, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("translation-latency.json"), options: .atomic)
    }

    /// Three lengths in each direction expose output-length effects instead of reducing the
    /// comparison to a fast greeting. Every model receives exactly the same complete targets.
    private static let fixtures = [
        Fixture(id: "zh-short", source: "你好，很高兴认识你。", language: .chinese, target: .english),
        Fixture(id: "zh-medium", source: "我今天已经完成了代码审查，明天准备发布新版本。", language: .chinese, target: .english),
        Fixture(id: "zh-long", source: "这个问题可能与输入法状态有关，请在确认候选词后重新测试，并告诉我替换是否成功。",
            language: .chinese, target: .english),
        Fixture(id: "en-short", source: "Please keep me posted on the progress.", language: .english, target: .chinese),
        Fixture(id: "en-medium", source: "I have finished reviewing the changes and will publish the update tomorrow.",
            language: .english, target: .chinese),
        Fixture(id: "en-long", source: "The preview should appear next to the cursor only when the translated sentence is ready, " +
            "without covering the text being edited.",
            language: .english, target: .chinese)
    ]

    private struct Fixture {
        let id: String
        let source: String
        let language: LearningLanguage
        let target: LearningLanguage
    }

    private struct Row: Encodable {
        let model: String
        let round: Int
        let residency: String
        let fixture: String
        let sourceLanguage: String
        let targetLanguage: String
        let source: String
        let translation: String
        let contextTokens: Int
        let firstOutputMs: Int?
        let usableMs: Int?
        let displayMs: Int?
        let wallMs: Double
        let prefixPublications: Int
        let firstPrefix: String
        let thermalState: Int
    }

    private struct Report: Encodable {
        let optimization = "Release"
        let timingBoundary = "Translation service start to first nonblank streamed prefix submitted to the nonactivating AppKit panel; " +
            "excludes input pause, AX capture and compositor. wallMs measures final panel submission."
        let displayMode = "streaming; immediate first safe prefix, later prefixes coalesced to 30 Hz, replacement only after completion"
        let chip = ProcessInfo.processInfo.environment["COTABBY_TRANSLATION_LATENCY_CHIP"] ?? "unrecorded"
        let inputPauseMs = 600
        let referenceMode = "currentSentence"
        let sampling = "recommended adapter defaults; no overrides"
        let responseCache = "none"
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let thermalStateAtStart: Int
        var thermalStateAtEnd: Int?
        var rows: [Row] = []
    }
}
