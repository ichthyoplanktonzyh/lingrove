import Foundation
import Testing
@testable import Lingrove

/// These fixtures assert search boundaries rather than model wording: senses stay separate,
/// incidental example topics stay out, and only adopted semantic knowledge contributes.
@MainActor
struct VocabularySearchPolicyTests {
    @Test func materialIncludesMeaningsAndCuesButNeverExamplesOrPersonalNotes() throws {
        var document = VocabularySemanticTests.fixture()
        document.entries[0].senses[0].note = "PRIVATE_NOTE_SENTINEL"
        document.entries[0].senses[0].examples[0].text = "INCIDENTAL_TOPIC_SENTINEL"
        let records = VocabularySearchPolicy.documents(entries: document.entries, semantics: document.semantics)
        let first = try #require(records.first { $0.id == document.entries[0].senses[0].id })
        #expect(first.text.contains("推迟安排"))
        #expect(first.text.contains("改一改"))
        #expect(!first.text.contains("SENTINEL"))
        #expect(VocabularySearchPolicy.hits(documents: records, query: "INCIDENTAL_TOPIC_SENTINEL").isEmpty)
        #expect(VocabularySearchPolicy.hits(documents: records, query: "PRIVATE_NOTE_SENTINEL").isEmpty)
        #expect(first.selection.entryID == document.entries[0].id)
        #expect(records.count == 3)
        let other = try #require(records.first { $0.id == document.entries[0].senses[1].id })
        #expect(!other.text.contains("推迟安排"))
    }

    @Test func unclassifiedSensesAreSearchableAndProposedKnowledgeIsExcluded() {
        var document = VocabularySemanticTests.fixture()
        for index in document.semantics.mappings.indices { document.semantics.mappings[index].provenance.status = .proposed }
        let records = VocabularySearchPolicy.documents(entries: document.entries, semantics: document.semantics)
        #expect(records.count == 3)
        #expect(records.allSatisfy { !$0.text.contains("改一改") })
        #expect(!VocabularySearchPolicy.hits(documents: records, query: "延期").isEmpty)
    }

    @Test func contextOnlyCollectionsUseTheirInterpretationWithoutTheSourceSentence() throws {
        var document = VocabularySemanticTests.fixture()
        document.entries[0].senses[0].meaning = ""
        document.semantics = .init()
        let records = VocabularySearchPolicy.documents(entries: document.entries, semantics: document.semantics)
        let record = try #require(records.first { $0.id == document.entries[0].senses[0].id })
        #expect(record.text.contains("推迟会议"))
        #expect(!record.text.contains("Friday"))
        #expect(!record.text.contains("周五"))
    }

    @Test func hybridFusionDeduplicatesSensesAndPreservesExactExpressionLookup() throws {
        let document = VocabularySemanticTests.fixture()
        let records = VocabularySearchPolicy.documents(entries: document.entries, semantics: document.semantics)
        let semanticWinner = try #require(records.first { $0.expression == "postpone" })
        let scores = Dictionary(uniqueKeysWithValues: records.map { ($0.id, Float($0.id == semanticWinner.id ? 0.95 : 0.6)) })
        let hits = VocabularySearchPolicy.hits(documents: records, query: "push back", similarities: scores)
        #expect(hits.first?.document.expression == "push back")
        #expect(Set(hits.map(\.id)).count == hits.count)
        #expect(hits.contains { $0.id == semanticWinner.id })
        #expect(VocabularySearchPolicy.hits(documents: records, query: "   ", similarities: scores).isEmpty)
    }

    @Test func materialsAndQueriesAreBoundedAndUnicodeIsPreserved() throws {
        var document = VocabularySemanticTests.fixture()
        document.entries[0].senses[0].meaning = String(repeating: "日本語 العربية हिन्दी ", count: 1_000)
        let records = VocabularySearchPolicy.documents(entries: document.entries, semantics: document.semantics)
        #expect(records.allSatisfy { $0.text.count <= 2_000 })
        #expect(records[0].text.contains("日本語 العربية हिन्दी"))
        #expect(VocabularySearchPolicy.queryText(String(repeating: "好", count: 5_000)).count < 1_200)
        #expect(VocabularySearchPolicy.normalized("ＣＡＦÉ") == VocabularySearchPolicy.normalized("cafe"))
        #expect(VocabularySearchPolicy.fingerprint("延期") != VocabularySearchPolicy.fingerprint("中止"))
    }

    @Test func aPositiveVectorOrFirstPlaceAloneCannotAdmitAnUnrelatedAnswer() {
        let fixture = VocabularySemanticTests.fixture()
        let records = VocabularySearchPolicy.documents(entries: fixture.entries, semantics: fixture.semantics)
        let scores: [Float] = [0.47, 0.2, 0.01]
        let similarities = Dictionary(uniqueKeysWithValues: zip(records, scores).map { ($0.0.id, $0.1) })
        #expect(VocabularySearchPolicy.hits(documents: records, query: "火山喷发", similarities: similarities).isEmpty)
        #expect(VocabularySearchPolicy.hits(documents: records, query: "Friday", similarities: similarities).isEmpty)
        for invalid in [Float.nan, .infinity, -.infinity, 1.2, -1.2] {
            #expect(VocabularySearchPolicy.hits(documents: records, query: "火山喷发",
                similarities: [records[0].id: invalid]).isEmpty)
        }
    }

    @Test func admissionTrimsTheTailWithoutFillingTheLimitAndIgnoresOutOfScopeScores() {
        let fixture = VocabularySemanticTests.fixture()
        let records = VocabularySearchPolicy.documents(entries: fixture.entries, semantics: fixture.semantics)
        let scores: [UUID: Float] = [records[0].id: 0.90, records[1].id: 0.87, records[2].id: 0.70]
        let hits = VocabularySearchPolicy.hits(documents: records, query: "unwritten paraphrase", similarities: scores)
        #expect(hits.map(\.id) == [records[0].id, records[1].id])
        let scoped = VocabularySearchPolicy.hits(documents: [records[2]], query: "unwritten paraphrase", similarities: scores)
        #expect(scoped.map(\.id) == [records[2].id])
        #expect(VocabularySearchRelevancePolicy.cutoff(for: [.nan, .infinity, 1.2]) == 0.48)
        #expect(VocabularySearchPolicy.hits(documents: [records[2]], query: "unwritten paraphrase",
            similarities: [records[2].id: 0.48]).count == 1)
    }

    @Test func literalMatchesSurviveWeakVectorsButNeedAContiguousWholeWordPhrase() throws {
        let fixture = VocabularySemanticTests.fixture()
        let records = VocabularySearchPolicy.documents(entries: fixture.entries, semantics: fixture.semantics)
        let postpone = try #require(records.first { $0.expression == "postpone" })
        #expect(VocabularySearchPolicy.hits(documents: records, query: "postpone",
            similarities: [postpone.id: 0.1]).first?.id == postpone.id)
        #expect(VocabularySearchPolicy.keywordScore(postpone, query: "on") == 0)
        #expect(VocabularySearchPolicy.keywordScore(records[0], query: "push") > 0)
        #expect(VocabularySearchPolicy.keywordScore(records[0], query: "推迟") > 0)
        #expect(VocabularySearchPolicy.keywordScore(records[0], query: "push 延期") == 0)
    }

    @Test func aDefinitionComparisonCannotBypassSemanticAdmission() throws {
        let now = Date()
        let entries = [("postpone", "推迟"), ("expedite", "加快进程；与推迟不同。")].map { expression, meaning in
            VocabularyEntry(id: UUID(), expression: expression, dictionaryForm: expression, language: .english,
                kind: .word, senses: [.init(id: UUID(), meaning: meaning, createdAt: now, updatedAt: now)],
                createdAt: now, updatedAt: now)
        }
        let records = VocabularySearchPolicy.documents(entries: entries, semantics: .init())
        #expect(VocabularySearchPolicy.keywordScore(records[1], query: "推迟") == 40)
        let scores: [UUID: Float] = [records[0].id: 0.80, records[1].id: 0.48]
        let hits = VocabularySearchPolicy.hits(documents: records, query: "推迟", similarities: scores)
        #expect(hits.map(\.document.expression) == ["postpone"])
        #expect(VocabularySearchPolicy.hits(documents: records, query: "expedite", similarities: scores)
            .first?.document.expression == "expedite")
        // Exact confirmed cues remain deliberate routes, even when embedding similarity is low.
        let exact = VocabularySearchPolicy.hits(documents: records, query: "推迟", similarities: [records[0].id: 0.1])
        #expect(exact.map(\.document.expression) == ["postpone"])
        #expect(VocabularySearchPolicy.hits(documents: records, query: "加快").count == 1)
    }

    @Test func embeddingWeightsCannotBeAssignedToGenerativeTasks() {
        for task in LocalModelTask.allCases {
            #expect(!LocalModelTaskPolicy.supports(VocabularySearchCatalog.model.filename, task: task))
        }
    }
}
