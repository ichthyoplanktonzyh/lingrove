import Combine
import Foundation
import Testing
@testable import Cotabby

/// Explicit lookup starts one contextual request. Tabs and source choices are independent
/// navigation, so neither a stopped request nor an unchanged target is silently regenerated.
@MainActor
struct LearningContextualQueryTests {
    @Test func defaultSenseIsImmediateAndDictionaryIsLazyWithoutRestartingStoppedWork() async throws {
        let provider = QueryDictionary(), explainer = QueryExplainer()
        let session = LearningDictionarySession(provider: provider, explanationService: explainer)
        defer { session.close(); explainer.finishAll() }
        let sentence = "Please keep me posted."
        let range = (sentence as NSString).range(of: "keep me posted")
        let unit = LearningUnit(id: range.location, surface: "keep me posted", query: "keep someone posted", kind: .pattern,
            ranges: [range], words: LearningUnitPolicy.words(in: sentence, language: .english)
                .filter { NSIntersectionRange($0.range, range).length > 0 })
        let capture = VocabularyCapture(expression: unit.query, dictionaryForm: unit.query, language: .english, kind: .pattern,
            example: VocabularyPolicy.example(text: sentence, ranges: [range], language: .english))
        session.open(unit, documentID: UUID(), language: .english, vocabularyCapture: capture)
        await settle { explainer.pending.count == 1 }
        #expect(session.page == .contextual && session.explanation.isGenerating)
        #expect(session.favoriteCapture?.example?.text == sentence)
        #expect(explainer.pending[0].0.target == unit.query && explainer.pending[0].0.context == sentence)
        #expect(await provider.calls == 0)
        session.selectPage(.dictionary)
        await settle { session.content != .loading }
        session.selectPage(.contextual)
        session.explanation.cancel()
        session.selectPage(.dictionary); session.selectPage(.contextual)
        session.selectSource(.system)
        await settle { session.content != .loading }
        #expect(explainer.pending.count == 1 && !session.explanation.isGenerating)
        explainer.finishAll()
        await Task.yield()
        #expect(session.explanation.record == nil)
        session.select(try #require(unit.words.first))
        await settle { explainer.pending.count == 2 }
        #expect(session.page == .contextual && session.explanation.input?.target == "keep")
        session.close(); explainer.finishAll()
        await Task.yield()
        #expect(session.explanation.record == nil && !session.explanation.isGenerating)
    }

    @Test func unconfiguredSenseKeepsDictionaryAvailableWithoutStartingAModel() async {
        let provider = QueryDictionary(), explainer = QueryExplainer()
        explainer.isConfigured = false
        let session = LearningDictionarySession(provider: provider, explanationService: explainer)
        defer { session.close() }
        let unit = LearningUnit(id: 0, surface: "know", query: "know", kind: .word,
            ranges: [NSRange(location: 0, length: 4)], words: [])
        session.open(unit, documentID: UUID(), language: .english)
        #expect(session.page == .contextual && !session.explanation.isGenerating && explainer.pending.isEmpty)
        session.selectPage(.dictionary)
        await settle { session.content != .loading }
        #expect(await provider.calls == 1)
    }

    @Test func queuedTabNavigationCannotAffectAReopenedIdenticalQuery() async {
        let provider = QueryDictionary(), explainer = QueryExplainer()
        explainer.isConfigured = false
        let session = LearningDictionarySession(provider: provider, explanationService: explainer)
        defer { session.close() }
        let unit = LearningUnit(id: 0, surface: "know", query: "know", kind: .word,
            ranges: [NSRange(location: 0, length: 4)], words: [])
        let documentID = UUID()
        session.open(unit, documentID: documentID, language: .english)
        let retiredTarget = session.targetIdentity
        let queued = Task { session.selectPage(.dictionary, targetIdentity: retiredTarget) }
        session.close()
        session.open(unit, documentID: documentID, language: .english)
        await queued.value
        #expect(session.page == .contextual && session.targetIdentity != retiredTarget)
        #expect(await provider.calls == 0)

        let current = session.targetIdentity
        session.selectPage(.dictionary, targetIdentity: current)
        await settle { session.content != .loading }
        session.selectSource(.system)
        await settle { session.content != .loading }
        session.selectPage(.contextual, targetIdentity: current)
        #expect(session.page == .contextual && session.targetIdentity == current)
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<200 where !predicate() { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(predicate())
    }
}

private actor QueryDictionary: LearningDictionaryProviding {
    var calls = 0
    func lookup(_ query: String, language: LearningLanguage, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        calls += 1
        return .systemText("Live dictionary result")
    }
}

@MainActor private final class QueryExplainer: LearningExplanationGenerating {
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    var language: LearningLanguage { .chinese }
    var isConfigured = true
    var pending: [(LearningExplanationInput, CheckedContinuation<LearningExplanationRecord, any Error>?)] = []
    func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        try await withCheckedThrowingContinuation { pending.append((input, $0)) }
    }
    func finishAll() {
        for index in pending.indices {
            guard let continuation = pending[index].1 else { continue }
            pending[index].1 = nil
            continuation.resume(returning: .init(id: UUID(), input: pending[index].0, language: language,
                result: .init(meaning: "语境释义", explanation: "用法说明"), model: "fixture", createdAt: Date()))
        }
    }
    func recordDisplay(requestID: String) {}
}
