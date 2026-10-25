import Foundation
import Testing
@testable import Lingrove

/// Optional local-model regression for the reported README sentence and bare-word fallback.
/// Uses the real two-stage service and an existing local model, never downloads or endpoints.
@MainActor
struct LearningReadingContextIntegrationTests {
    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_READING_CONTEXT_GGUF"] != nil))
    func supportedWorksWithItsSentenceAndWithoutContext() async throws {
        let path = try #require(LingroveCompatibility.processEnvironment["LINGROVE_READING_CONTEXT_GGUF"])
        let suite = "lingrove.test.reading.context.native.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LanguageLearningSettings(defaults: defaults)
        settings.explanation.localModel = URL(fileURLWithPath: path).lastPathComponent
        settings.explanationLanguage = .chinese
        let native = ReadingContextRecordingRuntime()
        defer {
            if let output = LingroveCompatibility.processEnvironment["LINGROVE_READING_CONTEXT_REPORT"],
               let data = try? JSONSerialization.data(withJSONObject: native.replies, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output + ".raw.json"))
            }
        }
        let controller = LearningModelController(profile: settings.explanation,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)), core: native,
            localModelURL: { _ in URL(fileURLWithPath: path) })
        defer { controller.shutdownSync() }
        let service = LearningExplanationService(settings: settings, model: controller, telemetry: LearningRequestTelemetry())
        let sentence = "Lingrove is built around two equally core capabilities that work together in any supported macOS text field:"
        var results: [[String: String]] = []
        for contextKind in [LearningExplanationContext.sentence, .none] {
            let context = contextKind == .none ? "supported" : sentence
            let input = LearningLookupInput(target: .init(target: "supported", dictionaryForm: "supported", language: .english,
                kind: .word, context: context, ranges: [.init((context as NSString).range(of: "supported"))],
                contextKind: contextKind), translationLanguage: .chinese)
            for _ in 0..<3 {
                let basic = try await service.lookup(input, requestID: RequestID.generate(), refresh: true)
                #expect(basic.result.meaning.contains("支持") || basic.result.meaning.contains("兼容"))
                #expect(contextKind == .none ? basic.result.sentenceTranslation.isEmpty : !basic.result.sentenceTranslation.isEmpty)
                results.append(["scope": contextKind.rawValue, "meaning": basic.result.meaning,
                                "sentence_translation": basic.result.sentenceTranslation])
            }
        }
        if let output = LingroveCompatibility.processEnvironment["LINGROVE_READING_CONTEXT_REPORT"] {
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }
}

/// Captures only opt-in fixture outputs while delegating every native operation to production.
/// The controller calls from a worker thread, so one lock owns the diagnostic reply array.
private nonisolated final class ReadingContextRecordingRuntime: LearningLocalExecuting, @unchecked Sendable {
    private let runtime = LearningLocalRuntime()
    private let lock = NSLock()
    private var values: [[String: String]] = []
    var replies: [[String: String]] { lock.withLock { values } }
    func claim(_ operation: UUID) { runtime.claim(operation) }
    func invalidate() -> UUID { runtime.invalidate() }
    func prepare(modelURL: URL, operationID: UUID, trace: LearningRequestContext?) throws {
        try runtime.prepare(modelURL: modelURL, operationID: operationID, trace: trace)
    }
    // swiftlint:disable:next function_parameter_count
    func generate(modelURL: URL, template: LearningChatTemplate, prompt: String, maxTokens: Int,
                  operationID: UUID, trace: LearningRequestContext?, onLoad: (@Sendable (Int) -> Void)?,
                  onDelta: @Sendable (String) -> Void) throws -> String {
        try generate(configuration: .init(modelURL: modelURL, template: template, contextWindowTokens: 8_192), prompt: prompt, maxTokens: maxTokens,
            operationID: operationID, trace: trace, onLoad: onLoad, onDelta: onDelta)
    }
    func generate(configuration: LearningLocalModelConfiguration, prompt: String, maxTokens: Int,
                  operationID: UUID, trace: LearningRequestContext?, onLoad: (@Sendable (Int) -> Void)?,
                  onDelta: @Sendable (String) -> Void) throws -> String {
        let output = try runtime.generate(configuration: configuration, prompt: prompt, maxTokens: maxTokens,
            operationID: operationID, trace: trace, onLoad: onLoad, onDelta: onDelta)
        lock.withLock { values.append(["prompt": prompt, "output": output]) }
        return output
    }
    func cancel(_ operation: UUID?) { runtime.cancel(operation) }
    func unload(expectedLease: UUID?, trace: LearningRequestContext?) { runtime.unload(expectedLease: expectedLease, trace: trace) }
    func shutdownSync() { runtime.shutdownSync() }
}
