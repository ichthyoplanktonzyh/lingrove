import Foundation
import Testing
@testable import Lingrove

/// Opt-in Release validation borrows an already-downloaded general model. It performs no download,
/// uses isolated preferences and exercises the exact controller/service/parser used by the cards.
@MainActor
struct LearningExplanationIntegrationTests {
    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_EXPLANATION_GGUF"] != nil))
    func existingGeneralModelExplainsWordExpressionAndSentence() async throws {
        let path = try #require(LingroveCompatibility.processEnvironment["LINGROVE_EXPLANATION_GGUF"])
        let name = "lingrove.test.nativeExplanation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageLearningSettings(defaults: defaults)
        settings.explanation.localModel = URL(fileURLWithPath: path).lastPathComponent
        settings.explanationLanguage = .chinese
        let controller = LearningModelController(profile: settings.explanation,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            localModelURL: { _ in URL(fileURLWithPath: path) })
        defer { controller.shutdownSync() }
        let service = LearningExplanationService(settings: settings, model: controller, telemetry: LearningRequestTelemetry())
        // Keep the expected query grain independent from target/context wording in this fixture.
        // swiftlint:disable:next large_tuple
        let cases: [(String, String, VocabularyEntry.Kind)] = [
            ("know", "Please let me know as soon as possible about any updates on the project.", .word),
            ("keep me posted", "Please keep me posted on the progress.", .expression),
            ("bank", "She deposited her savings at the bank.", .word),
            ("bank", "They sat on the bank of the river.", .word),
            ("address", "Okay, let's address the first issue now.", .word),
            ("flashcard", "On the flashcard, click.", .word),
            ("If it rains tomorrow, we will stay home.", "If it rains tomorrow, we will stay home.", .sentence)
        ]
        var rows: [[String: Any]] = []
        for (target, context, kind) in cases {
            let input = LearningExplanationInput(target: target, dictionaryForm: target, language: .english, kind: kind,
                context: context, ranges: [.init((context as NSString).range(of: target))], contextKind: .sentence)
            let start = ProcessInfo.processInfo.systemUptime
            let record = try await service.generate(input, requestID: RequestID.generate(), refresh: true)
            #expect(!record.result.meaning.isEmpty && !record.result.explanation.isEmpty)
            #expect(!record.result.explanation.contains("<think>"))
            #expect(record.language == .chinese && LearningLanguage.detect(in: record.result.explanation) == .chinese,
                "The selected explanation language applies to the prose, not just the record metadata")
            rows.append(["target": target, "context": context, "model": record.model,
                "meaning": record.result.meaning, "explanation": record.result.explanation,
                "latency_ms": Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)])
        }
        if let output = LingroveCompatibility.processEnvironment["LINGROVE_EXPLANATION_REPORT"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }
}
