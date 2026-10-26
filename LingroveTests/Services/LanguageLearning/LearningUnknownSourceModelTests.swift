import Foundation
import Testing
@testable import Lingrove

/// Opt-in, on-device checks compare known and omitted source metadata on identical material.
/// No weights are downloaded and no endpoint receives the fixtures or user's notebook data.
@Suite(.serialized, .timeLimit(.minutes(4)))
@MainActor
struct LearningUnknownSourceModelTests {
    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_UNKNOWN_SOURCE_MODEL_DIR"] != nil))
    func contextualLookupWithoutSourceStillReturnsThePairAndAnchoredDetails() async throws {
        let directory = try #require(LingroveCompatibility.processEnvironment["LINGROVE_UNKNOWN_SOURCE_MODEL_DIR"])
        let suite = "lingrove.test.unknown.lookup.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LanguageLearningSettings(defaults: defaults)
        settings.explanation.backend = .local
        settings.explanation.localModel = "Qwen3.5-4B-Q4_K_M.gguf"
        settings.explanationLanguage = .chinese
        let controller = LearningModelController(profile: settings.explanation,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            localModelURL: { URL(fileURLWithPath: directory).appendingPathComponent($0) })
        defer { controller.shutdownSync() }
        let service = LearningExplanationService(settings: settings, model: controller, telemetry: LearningRequestTelemetry())
        let sources: [LearningLanguage?] = [.english, nil]
        for source in sources {
            let context = "OpenAI-compatible chat endpoint"
            let input = LearningLookupInput(target: .init(target: "compatible", dictionaryForm: "compatible", language: source,
                kind: .word, context: context, ranges: [.init((context as NSString).range(of: "compatible"))], contextKind: .fragment),
                translationLanguage: .chinese)
            let basic = try await service.lookup(input, requestID: RequestID.generate(), refresh: true)
            #expect(basic.result.meaning.contains("兼容") || basic.result.meaning.contains("相容"))
            #expect(!basic.result.sentenceTranslation.isEmpty)
            #expect(basic.input.target.language == source)
            print("UNKNOWN_SOURCE_MODEL Qwen source=\(source?.rawValue ?? "auto") meaning=\(basic.result.meaning) translation=\(basic.result.sentenceTranslation)")
            if source == nil {
                let details = try await service.explainLookup(basic, requestID: RequestID.generate(), refresh: true)
                #expect(details.result.meaning == basic.result.meaning && !details.result.explanation.isEmpty)
            }
        }
    }

    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_UNKNOWN_SOURCE_MODEL_DIR"] != nil))
    func specialistTranslatorsAcceptTheSameTextWithoutSourceMetadata() async throws {
        let directory = try #require(LingroveCompatibility.processEnvironment["LINGROVE_UNKNOWN_SOURCE_MODEL_DIR"])
        for name in ["Hy-MT2-1.8B-Q4_K_M.gguf", "translategemma-4b-it-Q4_K_M.gguf"] {
            let suite = "lingrove.test.unknown.translation.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = LanguageLearningSettings(defaults: defaults)
            settings.translation.backend = .local
            settings.translation.localModel = name
            let controller = LearningModelController(profile: settings.translation,
                client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
                localModelURL: { URL(fileURLWithPath: directory).appendingPathComponent($0) })
            defer { controller.shutdownSync() }
            let sources: [LearningLanguage?] = [.english, nil]
            for source in sources {
                let plan = try await controller.translationPlan(input: .init(source: "OpenAI-compatible chat endpoint", origin: .reading),
                    sourceLanguage: source, targetLanguage: .chinese, output: 256)
                let raw = try await controller.generate(prompt: plan.prompt, maxTokens: 256,
                    userOnly: plan.userOnly, sampling: plan.sampling)
                let result = try LearningExpressionOutputPolicy.validatedText(raw)
                #expect(result.contains("兼容") || result.contains("相容"))
                print("UNKNOWN_SOURCE_MODEL \(name) source=\(source?.rawValue ?? "auto") translation=\(result)")
            }
        }
    }
}
