import Foundation
import Testing
@testable import Lingrove

/// Optional local acceptance uses an already downloaded general GGUF. Only fixture sentences
/// enter the model, and the exact production prompt/parser/controller execute both task stages.
@MainActor
struct LearningLookupIntegrationTests {
    /// Records protocol success and the actual prose for human review. It deliberately makes
    /// no assertions about word senses: model quality is not an application acceptance rule.
    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_LOOKUP_FORMAT_REPORT"] != nil))
    func reportOutputFormats() async throws {
        let path = try #require(LingroveCompatibility.processEnvironment["LINGROVE_LOOKUP_GGUF"])
        let report = try #require(LingroveCompatibility.processEnvironment["LINGROVE_LOOKUP_FORMAT_REPORT"])
        let suite = "lingrove.test.lookup.formats.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LanguageLearningSettings(defaults: defaults)
        settings.explanation.localModel = URL(fileURLWithPath: path).lastPathComponent
        settings.explanationLanguage = .chinese
        settings.explanation.setGenerationProfile(.init(
            sampling: .init(seedMode: .fixed, fixedSeed: 42), maximumOutputTokens: 1_024))
        let controller = LearningModelController(profile: settings.explanation,
            client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)),
            localModelURL: { _ in URL(fileURLWithPath: path) })
        defer { controller.shutdownSync() }
        let service = LearningExplanationService(settings: settings, model: controller, telemetry: LearningRequestTelemetry())
        // Each accepted pair is fixture evidence for the independent details stage, even when
        // a basic generation fails. Both versions therefore receive identical detail inputs.
        // swiftlint:disable:next large_tuple
        let cases: [(String, String, VocabularyEntry.Kind, String, String)] = [
            ("Hello", "Hello, it's nice to meet you.", .word, "你好", "你好，很高兴见到你。"),
            ("bank", "He sat on the bank of the river.", .word, "河岸", "他坐在河岸上。"),
            ("put off", "We had to put off the meeting until Friday.", .expression, "推迟", "我们不得不把会议推迟到星期五。"),
            ("bank", "bank", .word, "银行；河岸", "")
        ]
        var rows: [[String: String]] = []
        for (target, context, kind, meaning, translation) in cases {
            let input = LearningLookupInput(target: .init(target: target, dictionaryForm: target, language: .english,
                kind: kind, context: context, ranges: [.init((context as NSString).range(of: target))],
                contextKind: target == context ? .none : .sentence), translationLanguage: .chinese,
                referenceTranslation: translation)
            for stage in ["basic", "details", "full"] {
                var row = ["model": settings.explanation.localModel, "target": target, "context": context, "stage": stage]
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    if stage == "basic" {
                        let record = try await service.lookup(input, requestID: RequestID.generate(), refresh: true)
                        row["meaning"] = record.result.meaning
                        row["sentence_translation"] = record.result.sentenceTranslation
                    } else {
                        let basic = LearningLookupRecord(input: input, language: .chinese,
                            result: .init(meaning: meaning, sentenceTranslation: translation),
                            model: settings.explanation.localModel, createdAt: Date())
                        let record = stage == "full"
                            ? try await service.generate(input.target, requestID: RequestID.generate(), refresh: true)
                            : try await service.explainLookup(basic, requestID: RequestID.generate(), refresh: true)
                        row["meaning"] = record.result.meaning
                        row["explanation"] = record.result.explanation
                    }
                    row["outcome"] = "completed"
                } catch {
                    row["outcome"] = "failed"
                    row["error"] = error.localizedDescription
                }
                row["elapsed_ms"] = String(Int((ProcessInfo.processInfo.systemUptime - start) * 1_000))
                rows.append(row)
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: report))
    }

    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_LOOKUP_GGUF"] != nil))
    func aGeneralModelReturnsConsistentPairsBeforeAnyDetails() async throws {
        let path = try #require(LingroveCompatibility.processEnvironment["LINGROVE_LOOKUP_GGUF"])
        let name = "lingrove.test.lookup.native.\(UUID())"
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
        let cases = [("bank", "He sat on the bank of the river.", "岸"),
                     ("bank", "She deposited her savings at the bank.", "银行"),
                     ("put off", "We had to put off the meeting until Friday.", "推迟")]
        var rows: [[String: String]] = []
        for (target, sentence, expected) in cases {
            let input = LearningLookupInput(target: .init(target: target, dictionaryForm: target, language: .english,
                kind: target.contains(" ") ? .expression : .word, context: sentence,
                ranges: [.init((sentence as NSString).range(of: target))], contextKind: .sentence), translationLanguage: .chinese)
            let record = try await service.lookup(input, requestID: RequestID.generate(), refresh: true)
            #expect(record.result.meaning.contains(expected))
            #expect(!record.result.sentenceTranslation.isEmpty)
            rows.append(["target": target, "sentence": sentence, "meaning": record.result.meaning,
                         "sentence_translation": record.result.sentenceTranslation])
            if target == "put off" {
                let details = try await service.explainLookup(record, requestID: RequestID.generate(), refresh: true)
                #expect(details.result.meaning == record.result.meaning && !details.result.explanation.isEmpty)
                rows[rows.count - 1]["explanation"] = details.result.explanation
            }
        }
        if let report = LingroveCompatibility.processEnvironment["LINGROVE_LOOKUP_REPORT"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: report))
        }
    }
}
