#if DEBUG
import Combine
import SwiftUI

/// Canvas owns these sample states rather than a live editor or a model request. This fixture
/// boundary feeds real card sessions through their public APIs, so changes to production views
/// appear in previews without copying their layout or exposing setters just for design work.
nonisolated enum LearningCardPreviewState: String, CaseIterable, Identifiable {
    case ready = "正常", loading = "生成中", failure = "错误", longText = "长文本"
    var id: Self { self }
}

/// One mounted preview owns its sessions, isolated preferences and in-memory notebook. StateObject
/// retains it across SwiftUI body updates; disappearing cancels pending sample work and playback.
@MainActor
final class LearningCardPreviewModel: ObservableObject {
    let store = VocabularyStore(archive: VocabularyArchive(url: nil))
    let explanation: LearningExplanationSession
    let dictionary: LearningDictionarySession
    let speech: LearningSpeechController
    private let defaults: UserDefaults
    private let suite: String
    private var preparationID = UUID()
    private var active = true

    init(state: LearningCardPreviewState) {
        let suite = "io.ichthyoplanktonzyh.lingrove.card-preview.\(UUID().uuidString)"
        self.suite = suite
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Cannot create preview preferences") }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suite)
        let explainer = LearningPreviewExplainer(state: state)
        explanation = LearningExplanationSession(service: explainer)
        dictionary = LearningDictionarySession(provider: LearningPreviewDictionary(state: state), explanationService: explainer)
        let settings = LearningSpeechSettings(defaults: defaults, credentialStore: InMemoryOpenAICompatibleCredentialStore())
        speech = LearningSpeechController(settings: settings, provider: LearningPreviewSpeech(), generator: HomeDemoAudioGenerator())
        explanation.setTarget(HomeLearningDemoFixtures.input)
    }

    func prepare(state: LearningCardPreviewState, dictionaryPage: Bool) async {
        guard active, !Task.isCancelled else { return }
        let id = UUID()
        preparationID = id
        await store.load()
        guard active, !Task.isCancelled, preparationID == id else { return }
        dictionary.open(HomeLearningDemoFixtures.unit, documentID: HomeLearningDemoFixtures.documentID,
            language: .english, speechContext: HomeLearningDemoFixtures.translation,
            vocabularyCapture: HomeLearningDemoFixtures.capture)
        if dictionaryPage { dictionary.selectPage(.dictionary) }
        if state == .loading || state == .failure { explanation.explain() }
    }

    func stop() {
        active = false
        preparationID = UUID()
        store.openSelection = nil
        explanation.cancel()
        dictionary.close()
        speech.shutdown()
        defaults.removePersistentDomain(forName: suite)
    }

    /// Reopening is synchronous so a queued task cannot revive a preview stopped afterwards.
    func resume() { active = true }

    static func sentence(state: LearningCardPreviewState, expanded: Bool) -> LearningSentencePresentation {
        let longText = state == .longText
        let source = HomeLearningDemoFixtures.source + (longText ? "请在确认时间安排后告诉我，如果遇到任何问题，也请及时联系我，我们可以一起讨论解决方案。" : "")
        let extraTranslation = " Let me know once the schedule is confirmed. " +
            "If anything comes up, please get in touch so that we can work through it together."
        let translation = HomeLearningDemoFixtures.translation + (longText ? extraTranslation : "")
        var value = LearningSentencePresentation(id: HomeLearningDemoFixtures.documentID,
            source: source, translation: state == .loading ? "Please keep me posted" : translation,
            sourceLanguage: .chinese, targetLanguage: .english, caret: .zero, isExpanded: expanded,
            isGenerating: state == .loading, message: state == .failure ? "暂时无法生成译文，请重试。" : "",
            previousTranslation: nil, shortcutLabel: "", units: [HomeLearningDemoFixtures.unit],
            unitStage: .ready, canReplace: state != .loading && state != .failure)
        value.isTranslating = state == .loading
        value.isError = state == .failure
        return value
    }
}

/// Deliberate suspended/error responses exercise the existing session's loading, cancel and retry
/// paths. Ready records are restored synchronously, keeping Canvas deterministic and offline.
@MainActor
private final class LearningPreviewExplainer: LearningLookupGenerating {
    let changes = PassthroughSubject<Void, Never>().eraseToAnyPublisher()
    let language = LearningLanguage.chinese
    let isConfigured = true
    let state: LearningCardPreviewState
    init(state: LearningCardPreviewState) { self.state = state }
    func savedRecord(for input: LearningExplanationInput) -> LearningExplanationRecord? {
        guard state == .ready || state == .longText else { return nil }
        return record(input)
    }
    func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        try await Task.sleep(for: state == .loading ? .seconds(3_600) : .milliseconds(250))
        try Task.checkCancellation()
        if state == .failure { throw LearningFailure.message("暂时无法生成解释，请重试。") }
        return record(input)
    }
    private func record(_ input: LearningExplanationInput) -> LearningExplanationRecord {
        let original = HomeLearningDemoFixtures.record(input)
        guard state == .longText else { return original }
        return .init(id: original.id, input: input, language: .chinese,
            result: .init(meaning: original.result.meaning,
                explanation: Array(repeating: original.result.explanation, count: 5).joined(separator: "\n\n")),
            model: original.model, createdAt: original.createdAt)
    }
    func lookup(_ input: LearningLookupInput, requestID: String, refresh: Bool) async throws -> LearningLookupRecord {
        let record = try await generate(input.target, requestID: requestID, refresh: refresh)
        return .init(input: input, language: language,
            result: .init(meaning: record.result.meaning,
                sentenceTranslation: input.target.contextKind == .none ? ""
                    : input.referenceTranslation.isEmpty ? HomeLearningDemoFixtures.source : input.referenceTranslation),
            model: record.model, createdAt: record.createdAt)
    }
    func explainLookup(_ record: LearningLookupRecord, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        let details = try await generate(record.input.target, requestID: requestID, refresh: refresh)
        return .init(id: details.id, input: details.input, language: details.language,
            result: .init(meaning: record.result.meaning, explanation: details.result.explanation),
            model: details.model, createdAt: details.createdAt)
    }
    func recordDisplay(requestID: String) { }
}

/// The source picker still uses the real dictionary session. Only the data boundary is replaced;
/// no system DCS helper, website, downloaded dictionary or endpoint is queried from Canvas.
private nonisolated struct LearningPreviewDictionary: LearningDictionaryProviding {
    let state: LearningCardPreviewState
    func lookup(_ query: String, language: LearningLanguage?, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        if state == .loading { try await Task.sleep(for: .seconds(3_600)) }
        try Task.checkCancellation()
        if state == .failure { throw LearningFailure.message("当前词典不可用，请切换来源。") }
        if state == .longText {
            let entry = "\(query)\n使某人持续获知最新情况。\n" +
                "Please keep me posted on the project's progress.\n请随时告诉我项目的最新进展。"
            return .systemText(Array(repeating: entry, count: 8).joined(separator: "\n\n"))
        }
        return try await HomeDemoDictionary().lookup(query, language: language, expression: expression,
                                                    source: source, configuration: configuration)
    }
}

/// Silent playback preserves the real speaker button's playing/stopped feedback. Layout previews
/// must not enumerate installed voices, start AVSpeechSynthesizer or launch a local TTS process.
@MainActor
private final class LearningPreviewSpeech: SpeechProviding {
    var eventHandler: (@MainActor @Sendable (SpeechProviderEvent) -> Void)?
    func refreshVoices() throws -> [SpeechVoice] {
        [.init(id: "preview-en", name: "Preview", language: "en-US", quality: .standard),
         .init(id: "preview-zh", name: "Preview", language: "zh-CN", quality: .standard)]
    }
    func speak(_ text: String, voice: SpeechVoice, rateMultiplier: Double, token: SpeechPlaybackToken) throws {
        eventHandler?(.started(token))
    }
    func stop(token: SpeechPlaybackToken) { eventHandler?(.cancelled(token)) }
}
#endif
