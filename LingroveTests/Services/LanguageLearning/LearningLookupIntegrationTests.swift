import Foundation
import Testing
@testable import Lingrove

/// Optional local acceptance uses an already downloaded general GGUF. Only fixture sentences
/// enter the model, and the exact production prompt/parser/controller execute both task stages.
@MainActor
struct LearningLookupIntegrationTests {
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
