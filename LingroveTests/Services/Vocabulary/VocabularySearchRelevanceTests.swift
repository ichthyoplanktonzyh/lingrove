import Foundation
import Testing
@testable import Lingrove

/// Labeled searches exercise the real index and admission policy, including collections where
/// the intended answer is absent. Fixtures are synthetic; the user's notebook is never opened.
@Suite(.serialized)
@MainActor
struct VocabularySearchRelevanceTests {
    private struct Fixture: Decodable {
        struct Document: Decodable {
            let id: String
            let expression: String
            let meaning: String
        }
        struct Query: Decodable {
            let split: String
            let query: String
            let expected: [String]
            let pool: [String]?
        }
        let documents: [Document]
        let cases: [Query]
    }

    private struct Result: Codable {
        let split: String
        let query: String
        let expected: [String]
        let returned: [String]
        let expressions: [String]
    }

    private struct Metrics: Codable {
        var positiveQueries = 0
        var positiveQueriesWithHit = 0
        var correctFirstResults = 0
        var negativeQueries = 0
        var correctlyEmptyQueries = 0
        var returned = 0
        var relevantReturned = 0

        mutating func include(_ result: Result) {
            let expected = Set(result.expected)
            returned += result.returned.count
            relevantReturned += result.returned.filter { expected.contains($0) }.count
            if expected.isEmpty {
                negativeQueries += 1
                if result.returned.isEmpty { correctlyEmptyQueries += 1 }
            } else {
                positiveQueries += 1
                if result.returned.contains(where: expected.contains) { positiveQueriesWithHit += 1 }
                if let first = result.returned.first, expected.contains(first) { correctFirstResults += 1 }
            }
        }
    }

    private struct Report: Encodable {
        let model: String
        let minimumSimilarity: Float
        let maximumSimilarityGap: Float
        let metrics: [String: Metrics]
        let results: [Result]
    }

    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_SEARCH_MODEL_PATH"] != nil))
    func realModelRejectsUnrelatedQueriesAndMeasuresDifficultNeighbors() async throws {
        let path = try #require(LingroveCompatibility.processEnvironment["LINGROVE_SEARCH_MODEL_PATH"])
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/vocabulary-search-relevance.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let entries = try fixture.documents.map { source -> VocabularyEntry in
            let number = try #require(Int(source.id))
            let id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)))
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            return VocabularyEntry(id: UUID(), expression: source.expression, dictionaryForm: source.expression,
                language: .english, kind: .expression,
                senses: [.init(id: id, meaning: source.meaning, createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)
        }
        let documents = VocabularySearchPolicy.documents(entries: entries, semantics: .init())
        let keys = Dictionary(uniqueKeysWithValues: zip(documents, fixture.documents).map { ($0.0.id, $0.1.id) })
        let index = VocabularySearchIndex(cacheURL: nil)
        let modelURL = URL(fileURLWithPath: path)
        try await index.reconcile(documents, modelURL: modelURL) { _, _ in }
        var results: [Result] = []
        for item in fixture.cases {
            let scoped = documents.filter { document in
                guard let pool = item.pool, let key = keys[document.id] else { return true }
                return pool.contains(key)
            }
            let hits = try await index.search(item.query, documents: scoped, modelURL: modelURL)
            results.append(.init(split: item.split, query: item.query, expected: item.expected,
                returned: hits.compactMap { keys[$0.id] }, expressions: hits.map(\.document.expression)))
        }
        await index.unload()
        var metrics: [String: Metrics] = [:]
        for result in results { metrics[result.split, default: .init()].include(result) }
        for (split, values) in metrics {
            // Quality budgets preserve known model limitations rather than relabeling or dropping
            // counterexamples. Opposites can still score highly without a second model.
            #expect(Double(values.positiveQueriesWithHit) / Double(values.positiveQueries) >= 0.85, "Recall: \(split)")
            #expect(Double(values.relevantReturned) / Double(values.returned) >= 0.70, "Precision: \(split)")
            #expect(values.correctlyEmptyQueries >= values.negativeQueries - 2, "Absent answers: \(split)")
        }
        // Fully unrelated topics must be empty individually, not merely hidden by aggregate scores.
        for result in results where result.expected.isEmpty && !fixture.cases.contains(where: {
            $0.split == result.split && $0.query == result.query && $0.pool != nil
        }) {
            #expect(result.returned.isEmpty, "Unrelated query: \(result.query)")
        }
        if let reportPath = LingroveCompatibility.processEnvironment["LINGROVE_SEARCH_RELEVANCE_REPORT"] {
            let report = Report(model: VocabularySearchCatalog.identity,
                minimumSimilarity: VocabularySearchRelevancePolicy.minimumSimilarity,
                maximumSimilarityGap: VocabularySearchRelevancePolicy.maximumSimilarityGap, metrics: metrics, results: results)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
    }
}
