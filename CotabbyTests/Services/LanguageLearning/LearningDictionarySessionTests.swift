import Foundation
import Testing
@testable import Cotabby

@MainActor
struct LearningDictionarySessionTests {
    private func unit() -> LearningUnit {
        let text = "look forward to"
        return .init(id: 0, surface: text, query: text, kind: .expression,
            ranges: [.init(location: 0, length: text.utf16.count)],
            words: LearningUnitPolicy.words(in: text, language: .english))
    }
    private func settle(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !predicate() { await Task.yield() }
    }

    @Test
    func wholeExpressionMissAllowsWordNavigationAndReturningWithoutCombiningDefinitions() async {
        let provider = ControlledLearningDictionary()
        let session = LearningDictionarySession(provider: provider)
        let expression = unit()
        session.open(expression, documentID: UUID(), language: .english)
        await settle { session.content == .result(.notFound) }
        #expect(session.title == "look forward to")
        #expect(session.content == .result(.notFound))
        session.select(expression.words[1])
        await settle { session.content == .result(.systemText("Fixture definition.")) }
        #expect(session.title == "forward")
        session.returnToExpression()
        await settle { session.content == .result(.notFound) }
        #expect(session.content == .result(.notFound))
        #expect(session.selectedWord == nil)
        let calls = await provider.calls
        #expect(calls == ["expression:look forward to", "expression:look forward to", "word:forward"])
        session.close()
        #expect(session.unit == nil)
    }

    @Test
    func automaticFallbackAndExplicitSourceHaveDifferentScopes() async throws {
        let provider = SourceDictionaryProbe()
        let session = LearningDictionarySession(provider: provider)
        defer { session.close() }
        session.open(unit(), documentID: UUID(), language: .english)
        await settle { session.content == .result(.systemText("System definition")) }
        #expect(session.selectedSource == .system)
        #expect(await provider.calls == [.bundled, .system])
        session.selectSource(.bundled)
        await settle { session.content == .result(.notFound) }
        #expect(session.selectedSource == .bundled)
        #expect(await provider.calls == [.bundled, .system], "Explicit source uses its cached miss and must not fall back")
        session.selectSource(.system)
        await settle { session.content == .result(.systemText("System definition")) }
        #expect(await provider.calls == [.bundled, .system])
        let expression = try #require(session.unit)
        session.select(expression.words[0])
        await settle { session.content == .result(.systemText("System definition")) }
        #expect(await provider.calls == [.bundled, .system, .bundled, .system],
                "A different query resumes configured priority; source overrides are query-scoped")
    }

    @Test
    func sourceChangesAndSettingsEditsRetireInFlightResults() async throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningDictionarySettings(defaults: defaults)
        let provider = DelayedSourceDictionary()
        let session = LearningDictionarySession(provider: provider, settings: settings)
        defer { session.close() }
        session.open(unit(), documentID: UUID(), language: .english)
        await provider.waitFor(.bundled)
        session.selectSource(.system)
        await provider.waitFor(.system)
        await provider.finish(.bundled, result: .systemText("Retired source result"))
        settings.setEnabled(false, for: .system)
        await provider.waitFor(.bundled)
        await provider.finish(.system, result: .systemText("Disabled source result"))
        for _ in 0..<20 { await Task.yield() }
        #expect(session.content == .loading && session.selectedSource == .bundled)
        await provider.finish(.bundled, result: .systemText("Current settings result"))
        await settle { session.content == .result(.systemText("Current settings result")) }
        session.select(try #require(session.unit?.words.first))
        await provider.waitFor(.bundled)
        session.close()
        await provider.finish(.bundled, result: .systemText("Closed settings result"))
        for _ in 0..<20 { await Task.yield() }
        #expect(session.unit == nil && session.content == .loading)
    }

    @Test
    func changingSourceSettingsRefreshesOnlyTheDictionaryAndRejectsDisabledSources() async throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LearningDictionarySettings(defaults: defaults)
        let provider = SourceDictionaryProbe()
        let session = LearningDictionarySession(provider: provider, settings: settings)
        defer { session.close() }
        session.open(unit(), documentID: UUID(), language: .english)
        await settle { session.selectedSource == .system }
        settings.setEnabled(false, for: .system)
        await settle { session.content == .result(.notFound) }
        #expect(session.availableSources == [.bundled])
        session.selectSource(.system)
        #expect(session.selectedSource == .bundled && session.content == .result(.notFound))
        #expect(await provider.calls == [.bundled, .system, .bundled])
    }

    @Test
    func componentFavoriteKeepsItsSentenceAndOnlyItsOwnDefinition() async throws {
        let sentence = "We look forward to seeing you."
        let range = (sentence as NSString).range(of: "look forward to")
        let words = LearningUnitPolicy.words(in: sentence, language: .english).filter { NSIntersectionRange($0.range, range).length > 0 }
        let expression = LearningUnit(id: range.location, surface: "look forward to", query: "look forward to", kind: .expression,
                                      ranges: [range], words: words)
        var example = VocabularyPolicy.example(text: sentence, ranges: [range], language: .english,
            startsAtBoundary: true, endsAtBoundary: true, app: "com.apple.TextEdit")
        example?.translation = "我们期待见到你。"
        let capture = VocabularyCapture(expression: expression.surface, dictionaryForm: expression.query,
                                        language: .english, kind: .expression, example: example)
        let session = LearningDictionarySession(provider: ControlledLearningDictionary())
        defer { session.close() }
        session.open(expression, documentID: UUID(), language: .english, vocabularyCapture: capture)
        session.select(words[1])
        await settle { session.content == .result(.systemText("Fixture definition.")) }
        let saved = try #require(session.favoriteCapture)
        #expect(saved.expression == "forward" && saved.kind == .word)
        #expect(saved.example?.text == sentence && saved.example?.translation == "我们期待见到你。")
        #expect(saved.example?.ranges == [VocabularyTextRange(words[1].range)])
        #expect(saved.definitions.map(\.text) == ["Fixture definition."])
        session.returnToExpression()
        await settle { session.content == .result(.notFound) }
        #expect(session.favoriteCapture?.expression == expression.surface)
        #expect(session.contextExample?.ranges == [VocabularyTextRange(range)])
    }

    @Test
    func speechContextFollowsWordNavigationAndIsClearedForTheNextDocument() {
        let session = LearningDictionarySession(provider: ControlledLearningDictionary())
        defer { session.close() }
        let expression = unit()
        let context = "We look forward to seeing you tomorrow."
        session.open(expression, documentID: UUID(), language: .english, speechContext: context)
        session.select(expression.words[1])
        #expect(session.speechContext == context)
        session.returnToExpression()
        #expect(session.speechContext == context)
        session.open(expression, documentID: UUID(), language: .english)
        #expect(session.speechContext == nil)
        session.open(expression, documentID: UUID(), language: .english, speechContext: context)
        session.close()
        #expect(session.speechContext == nil)
    }

    @Test
    func outOfOrderQueryAndClosedSessionNeverPublishLateDefinitions() async {
        let provider = ControlledLearningDictionary(delayed: true)
        let session = LearningDictionarySession(provider: provider)
        let expression = unit()
        session.open(expression, documentID: UUID(), language: .english)
        await provider.waitFor("look forward to")
        session.select(expression.words[0])
        await provider.waitFor("look")
        await provider.finish("look", result: .systemText("Fixture definition."))
        await settle { session.content == .result(.systemText("Fixture definition.")) }
        await provider.finish("look forward to", result: .notFound)
        for _ in 0..<20 { await Task.yield() }
        #expect(session.title == "look")
        #expect(session.content == .result(.systemText("Fixture definition.")))
        session.select(expression.words[2])
        await provider.waitFor("to")
        session.close()
        await provider.finish("to", result: .systemText("Fixture definition."))
        for _ in 0..<20 { await Task.yield() }
        #expect(session.unit == nil && session.documentID == nil)
    }
}

private actor SourceDictionaryProbe: LearningDictionaryProviding {
    var calls: [LearningDictionarySource] = []
    func lookup(_ query: String, language: LearningLanguage, expression: Bool,
                source: LearningDictionarySource) async throws -> LearningDictionaryResult {
        calls.append(source)
        return source == .bundled ? .notFound : .systemText("System definition")
    }
}

private actor DelayedSourceDictionary: LearningDictionaryProviding {
    var pending: [LearningDictionarySource: CheckedContinuation<LearningDictionaryResult, Never>] = [:]
    var waiters: [LearningDictionarySource: CheckedContinuation<Void, Never>] = [:]
    func waitFor(_ source: LearningDictionarySource) async {
        if pending[source] != nil { return }
        await withCheckedContinuation { waiters[source] = $0 }
    }
    func lookup(_ query: String, language: LearningLanguage, expression: Bool,
                source: LearningDictionarySource) async throws -> LearningDictionaryResult {
        await withCheckedContinuation {
            pending[source] = $0
            waiters.removeValue(forKey: source)?.resume()
        }
    }
    func finish(_ source: LearningDictionarySource, result: LearningDictionaryResult) {
        pending.removeValue(forKey: source)?.resume(returning: result)
    }
}

private actor ControlledLearningDictionary: LearningDictionaryProviding {
    let delayed: Bool
    var calls: [String] = []
    var pending: [String: CheckedContinuation<LearningDictionaryResult, Never>] = [:]
    var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    func waitFor(_ query: String) async {
        if pending[query] != nil { return }
        await withCheckedContinuation { waiters[query] = $0 }
    }
    init(delayed: Bool = false) { self.delayed = delayed }
    func lookup(_ query: String, language: LearningLanguage, expression: Bool, source: LearningDictionarySource) async throws -> LearningDictionaryResult {
        calls.append((expression ? "expression:" : "word:") + query)
        if delayed {
            return await withCheckedContinuation {
                pending[query] = $0
                waiters.removeValue(forKey: query)?.resume()
            }
        }
        return expression ? .notFound : .systemText("Fixture definition.")
    }
    func finish(_ query: String, result: LearningDictionaryResult) { pending.removeValue(forKey: query)?.resume(returning: result) }
}
