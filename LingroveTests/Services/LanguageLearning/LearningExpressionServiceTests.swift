import Foundation
import Testing
@testable import Lingrove

/// Exercises the request and cancellation boundary using the production API client with an
/// in-process URLProtocol. The service owns task eligibility and stale-result checks; this harness
/// makes each endpoint response deterministic without contacting a configured model server.
@Suite(.serialized)
@MainActor
struct LearningExpressionServiceTests {
    @Test
    func translationStreamsSafePrefixesAndReturnsOnlyTheValidatedFinalText() async throws {
        let body = """
        data: {"choices":[{"delta":{"content":"  "},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":" world."},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]


        """
        let harness = try makeHarness(translationEnabled: true,
            reply: .init(statusCode: 200, body: Data(body.utf8)))
        defer { harness.cleanUp() }
        var prefixes: [String] = []
        let final = try await harness.service.translateSentence(input: .init(source: "你好，世界。"),
            sourceLanguage: .chinese, targetLanguage: .english, onPartial: { prefixes.append($0) })
        #expect(prefixes.first == "Hello", "Leading blank tokens must not open an empty card")
        #expect(final == "Hello world.")
        let request = await harness.exchange.waitForRequest()
        let requestBody = try #require(request.body)
        let json = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
    }

    @Test(arguments: LearningReadingSource.allCases)
    func eachReadingSourceNeedsOnlyOneTranslationRequest(_ source: LearningReadingSource) async throws {
        let harness = try makeHarness(translationEnabled: true, legacyAlignmentEnabled: true,
            sourceLanguages: [.english], targetLanguage: .chinese, reply: instructionResponse("I can do it."))
        defer { harness.cleanUp() }
        let learning = harness.settings.languageLearning
        learning.readingTargetLanguage = .english
        setReadingSource(source, enabled: true, in: learning)
        let translation = try await harness.service.translateReadingSelection(source: "我能做到",
            sourceLanguage: .chinese, targetLanguage: .english, readingSource: source)
        #expect(translation == "I can do it.")
        #expect(harness.exchange.requestCount == 1)
    }

    @Test(arguments: LearningReadingSource.allCases)
    func disabledReadingSourceCannotBorrowAnotherSourcesSwitch(_ source: LearningReadingSource) async throws {
        let harness = try makeHarness(translationEnabled: true)
        defer { harness.cleanUp() }
        let learning = harness.settings.languageLearning
        learning.readingTargetLanguage = .english
        for entry in LearningReadingSource.allCases { setReadingSource(entry, enabled: entry != source, in: learning) }
        do {
            _ = try await harness.service.translateReadingSelection(source: "我能做到", sourceLanguage: .chinese,
                targetLanguage: .english, readingSource: source)
            Issue.record("A disabled source must never start translation")
        } catch is LearningFailure {} catch { Issue.record("Expected disabled-direction failure, got \(error)") }
        #expect(harness.exchange.requestCount == 0)
    }

    @Test(arguments: LearningReadingSource.allCases)
    func closingReadingSourceRejectsLateTranslation(_ source: LearningReadingSource) async throws {
        let harness = try makeHarness(translationEnabled: true, holdResponse: true)
        defer { harness.cleanUp() }
        let learning = harness.settings.languageLearning
        learning.readingTargetLanguage = .english
        for entry in LearningReadingSource.allCases { setReadingSource(entry, enabled: true, in: learning) }
        let operation = Task {
            try await harness.service.translateReadingSelection(source: "我能做到", sourceLanguage: .chinese,
                targetLanguage: .english, readingSource: source)
        }
        _ = await harness.exchange.waitForRequest()
        setReadingSource(source, enabled: false, in: learning)
        harness.exchange.release(with: try instructionResponse("I can do it."))
        do {
            _ = try await operation.value
            Issue.record("A late result must be discarded when its own entry closes")
        } catch is CancellationError {} catch { Issue.record("Expected cancellation, got \(error)") }
        #expect(harness.exchange.requestCount == 1)
    }

    @Test(arguments: LearningReadingSource.allCases)
    func closingOtherSourcesKeepsPendingReadingWork(_ source: LearningReadingSource) async throws {
        let harness = try makeHarness(translationEnabled: true, holdResponse: true)
        defer { harness.cleanUp() }
        let learning = harness.settings.languageLearning
        learning.readingTargetLanguage = .english
        for entry in LearningReadingSource.allCases { setReadingSource(entry, enabled: true, in: learning) }
        let operation = Task {
            try await harness.service.translateReadingSelection(source: "我能做到", sourceLanguage: .chinese,
                targetLanguage: .english, readingSource: source)
        }
        _ = await harness.exchange.waitForRequest()
        for entry in LearningReadingSource.allCases where entry != source { setReadingSource(entry, enabled: false, in: learning) }
        harness.exchange.release(with: try instructionResponse("I can do it."))
        #expect(try await operation.value == "I can do it.")
        #expect(harness.exchange.requestCount == 1)
    }

    private func setReadingSource(_ source: LearningReadingSource, enabled: Bool, in settings: LanguageLearningSettings) {
        switch source {
        case .selection: settings.selectionTranslationEnabled = enabled
        case .pointer: settings.pointerTranslationEnabled = enabled
        case .screenshot: settings.screenshotTranslationEnabled = enabled
        }
    }

    @Test(arguments: ["translategemma:4b", "hy-mt2:7b", "learning-instruction-model"])
    func specialistEndpointUsesItsOwnPromptAndSampling(_ model: String) async throws {
        let harness = try makeHarness(translationEnabled: true, reply: instructionResponse("Hello."))
        defer { harness.cleanUp() }
        harness.settings.languageLearning.translation.endpointModel = model
        let text = try await harness.service.translateSentence(source: "你好", sourceLanguage: .chinese, targetLanguage: .english)
        #expect(text == "Hello.")
        let request = await harness.exchange.waitForRequest()
        let data = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        let family = LearningTranslationPrompt.Family(endpointModel: model)
        let expected = try LearningTranslationPrompt.render(source: "你好", sourceLanguage: .chinese,
            targetLanguage: .english, family: family)
        #expect(messages.count == (expected.userOnly ? 1 : 2))
        #expect(messages.last?["role"] == "user")
        #expect(messages.last?["content"] == expected.prompt)
        #expect(body["temperature"] as? Double == expected.sampling.temperature)
        #expect(body["top_p"] as? Double == expected.sampling.topP)
        #expect(harness.exchange.requestCount == 1)
    }

    @Test
    func legacyAlignmentConfigurationCannotStartAnotherRequestOrRedirectTranslation() async throws {
        let harness = try makeHarness(translationEnabled: true, legacyAlignmentEnabled: true, holdResponse: true)
        defer { harness.cleanUp() }
        let operation = Task { try await harness.service.translateSentence(source: "我能做到",
            sourceLanguage: .chinese, targetLanguage: .english) }
        _ = await harness.exchange.waitForRequest()
        harness.defaults.set("different-analyst", forKey: "learning.analysis.endpointModel")
        harness.settings.setOpenAICompatibleBaseURL("https://completion.invalid/v1")
        harness.exchange.release(with: try instructionResponse("I can do it."))
        #expect(try await operation.value == "I can do it.")
        #expect(harness.exchange.requestCount == 1)
        #expect(harness.defaults.bool(forKey: "learningAnalysisEnabled"), "Retiring the feature must not delete its experimental settings")
    }

    @Test
    func connectSubmitsDraftKeyAndKeepsDiscoverySeparateFromRuntime() async throws {
        let catalog = LearningExpressionServiceReply(statusCode: 200,
            body: Data(#"{"data":[{"id":"test-model"}]}"#.utf8))
        let failure = LearningExpressionServiceReply(statusCode: 500, body: Data())
        let harness = try makeHarness(reply: catalog, nextReply: failure)
        defer { harness.cleanUp() }
        let controller = harness.service.models.translation
        // Discovery is available even when the task uses a local model.
        controller.profile.backend = .local
        await controller.connect(using: "draft-test-key")
        let request = await harness.exchange.waitForRequest()
        #expect(request.headers["Authorization"] == "Bearer draft-test-key")
        #expect(request.method == "GET")
        #expect(request.url?.path == "/v1/models")
        #expect(controller.endpointConnection.models.map(\.id) == ["test-model"])
        #expect(controller.status == String(localized: "Not loaded", table: "Learning"))
        controller.profile.endpointModel = "custom-identifier"
        #expect(controller.endpointConnection.models.count == 1)
        await controller.discoverEndpoint()
        #expect(controller.endpointConnection.models.isEmpty)
        #expect(controller.endpointConnection.state.failureDetail != nil)
    }

    @Test(arguments: ["url", "key"])
    func endpointIdentityChangeRejectsLateDiscovery(_ change: String) async throws {
        let harness = try makeHarness(holdResponse: true)
        defer { harness.cleanUp() }
        let controller = harness.service.models.translation
        let discovery = Task { await controller.discoverEndpoint() }
        _ = await harness.exchange.waitForRequest()
        if change == "url" { controller.profile.baseURL = "https://new.invalid/v1" } else { controller.profile.saveAPIKey("new-key") }
        #expect(controller.endpointConnection.models.isEmpty)
        #expect(controller.endpointConnection.state == .idle)
        harness.exchange.release(with: .init(statusCode: 200,
            body: Data(#"{"data":[{"id":"obsolete-model"}]}"#.utf8)))
        await discovery.value
        #expect(controller.endpointConnection.models.isEmpty)
        #expect(controller.endpointConnection.state == .idle)
    }

    @Test
    func inactiveBatteryAndManualChoicesDoNotCancelActiveEndpointWork() async throws {
        let harness = try makeHarness(translationEnabled: true, holdResponse: true)
        defer { harness.cleanUp() }
        let profile = harness.settings.languageLearning.translation
        profile.setPowerSwitchingEnabled(true)
        let operation = Task { try await harness.service.translateSentence(source: "我能做到",
            sourceLanguage: .chinese, targetLanguage: .english) }
        _ = await harness.exchange.waitForRequest()
        profile.batteryProfile = .local("future-battery.gguf")
        profile.endpointModel = "future-manual-endpoint"
        profile.localModel = "future-manual.gguf"
        harness.exchange.release(with: try instructionResponse("I can do it."))
        #expect(try await operation.value == "I can do it.")
    }

    @Test
    func realTransportRecordsOnlyTranslationWithLegacyAlignmentEnabled() async throws {
        let harness = try makeHarness(translationEnabled: true, legacyAlignmentEnabled: true, trackingEnabled: true,
            reply: instructionResponse("I can do it."))
        defer { harness.cleanUp() }
        let text = try await harness.service.translateSentence(source: "我能做到", sourceLanguage: .chinese, targetLanguage: .english)
        #expect(text == "I can do it.")
        let row = try #require(harness.metrics.entries.first)
        #expect(harness.metrics.entries.count == 1 && row.source == .translation && row.outcome == .completed)
        #expect(row.requestID?.hasPrefix("req_") == true)
        #expect(row.firstOutputMs != nil && row.usableResultMs != nil)
        let data = try #require(harness.defaults.data(forKey: "lingrovePerformanceMetricEntries"))
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("我能做到"))
    }

    @Test
    func incompleteTranslationRetainsFirstOutputButNeverBecomesUsable() async throws {
        let harness = try makeHarness(translationEnabled: true, trackingEnabled: true,
            reply: instructionResponse("partial text", finishReason: "length"))
        defer { harness.cleanUp() }
        do {
            _ = try await harness.service.translateSentence(source: "我能做到", sourceLanguage: .chinese, targetLanguage: .english)
            Issue.record("Incomplete output must be rejected")
        } catch { #expect(error is OpenAICompatibleClientError) }
        let row = try #require(harness.metrics.entries.first)
        #expect(row.outcome == .failed)
        #expect(row.firstOutputMs != nil && row.usableResultMs == nil && row.displayMs == nil)
    }

    @Test
    func transportRespectsTheExistingDefaultOffTrackingSetting() async throws {
        let harness = try makeHarness(translationEnabled: true)
        defer { harness.cleanUp() }
        _ = try await harness.service.translateSentence(source: "我能做到", sourceLanguage: .chinese, targetLanguage: .english)
        #expect(harness.metrics.entries.isEmpty)
    }

    @Test
    func translationKeepsItsOwnModelAndCredential() async throws {
        let harness = try makeHarness(translationEnabled: true, reply: instructionResponse("I can do it."))
        defer { harness.cleanUp() }
        harness.settings.languageLearning.translation.saveAPIKey("translation-key")
        harness.settings.languageLearning.explanation.saveAPIKey("explanation-key")
        _ = try await harness.service.translateSentence(source: "我能做到", sourceLanguage: .chinese, targetLanguage: .english)
        let request = await harness.exchange.waitForRequest()
        #expect(request.headers["Authorization"] == "Bearer translation-key")
        let data = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "learning-instruction-model")
    }

    @Test
    func changedLearningModelRejectsBufferedTranslation() async throws {
        let harness = try makeHarness(translationEnabled: true, holdResponse: true)
        defer { harness.cleanUp() }
        let operation = Task { try await harness.service.translateSentence(source: "我能做到", sourceLanguage: .chinese,
            targetLanguage: .english) }
        _ = await harness.exchange.waitForRequest()
        harness.settings.languageLearning.model = "new-learning-model"
        harness.exchange.release(with: try instructionResponse("I can do it."))
        do {
            _ = try await operation.value
            Issue.record("A response from the previous model must not reach the display")
        } catch { #expect(error is CancellationError) }
    }

    @Test
    func disabledTranslationCancelsBeforeSending() async throws {
        let translationHarness = try makeHarness()
        defer { translationHarness.cleanUp() }
        await expectCancellationWithoutRequest(
            translationHarness,
            task: .translation(source: .chinese, target: .english),
            source: "我今天会晚到。"
        )

    }

    @Test
    func legacyVocabularyPreferencesCannotEnableTranslation() async throws {
        let harness = try makeHarness(legacyVocabularyEnabled: true)
        defer { harness.cleanUp() }

        await expectCancellationWithoutRequest(
            harness,
            task: .translation(source: .chinese, target: .english),
            source: "我明天会联系你。"
        )
        #expect(harness.defaults.bool(forKey: "learningVocabularyEnabled"))
        #expect(harness.defaults.bool(forKey: "learningTranslationVocabularyEnabled"))
    }

    @Test
    func translationUsesOnlyTheExplicitSourceWithoutClaimingInputMethodCommitEvidence() async throws {
        let source = "我明天会联系你。"
        let harness = try makeHarness(translationEnabled: true, legacyVocabularyEnabled: true)
        defer { harness.cleanUp() }

        let result = try await harness.service.generate(
            source: source,
            task: .translation(source: .chinese, target: .english)
        )
        let request = await harness.exchange.waitForRequest()
        let prompt = try instructionPrompt(from: request)

        #expect(result == "We can meet tomorrow.")
        let expectedPrompt = try LearningExpressionPrompt.translation(source: source)
        #expect(prompt == expectedPrompt)
        #expect(prompt.contains("Translate the following Chinese text into natural English."))
        #expect(!prompt.contains("committed"))
        #expect(!prompt.contains("Prefer these words"))
        #expect(!prompt.contains("apple banana"))
    }

    @Test
    func rejectsUnsupportedLanguageDirectionBeforeHttp() async throws {
        let harness = try makeHarness(
            translationEnabled: true,
            sourceLanguages: [.chinese],
            targetLanguage: .english
        )
        defer { harness.cleanUp() }

        do {
            _ = try await harness.service.generate(
                source: "The meeting is today.",
                task: .translation(source: .english, target: .chinese)
            )
            Issue.record("A source language outside the configured set must not reach the endpoint.")
        } catch let failure as LearningFailure {
            #expect(failure.errorDescription?.contains("source language") == true)
        }
        #expect(harness.exchange.requestCount == 0)
    }

    @Test
    func sourceBudgetRejectsWholeInputBeforeHttp() async throws {
        let translationHarness = try makeHarness(translationEnabled: true)
        defer { translationHarness.cleanUp() }
        do {
            _ = try await translationHarness.service.generate(
                source: String(repeating: "我", count: ModelContextBudget.maximumTextBytes / 3 + 1),
                task: .translation(source: .chinese, target: .english)
            )
            Issue.record("The complete oversized source must be rejected before transmission.")
        } catch let failure as LearningFailure {
            #expect(failure.errorDescription?.contains("budget") == true)
        }
        #expect(translationHarness.exchange.requestCount == 0)

    }

    @Test
    func alreadyCancelledTaskDoesNotReachTheEndpoint() async throws {
        let harness = try makeHarness(translationEnabled: true)
        defer { harness.cleanUp() }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await harness.service.generate(
                source: "我明天会联系你。",
                task: .translation(source: .chinese, target: .english)
            )
        }

        do {
            _ = try await task.value
            Issue.record("A task cancelled at service entry must not generate a response.")
        } catch is CancellationError {
            #expect(harness.exchange.requestCount == 0)
        }
    }

    @Test(arguments: StaleLearningChange.allCases)
    func rejectsLateResponseAfterSettingsOrGlobalAvailabilityChanges(_ change: StaleLearningChange) async throws {
        let harness = try makeHarness(translationEnabled: true, holdResponse: true)
        defer { harness.cleanUp() }
        let task = Task { @MainActor in
            try await harness.service.generate(
                source: "我明天会联系你。",
                task: .translation(source: .chinese, target: .english)
            )
        }

        _ = await harness.exchange.waitForRequest()
        switch change {
        case .learningSettings:
            harness.settings.languageLearning.targetLanguage = .spanish
        case .model:
            harness.settings.languageLearning.model = "replacement-instruction-model"
        case .endpoint:
            harness.settings.languageLearning.translation.baseURL = "https://replacement.learning.invalid/v1"
        case .credential:
            harness.settings.languageLearning.translation.saveAPIKey("replacement-secret")
        case .globalOptOut:
            harness.settings.setGloballyEnabled(false)
        case .temporaryPause:
            harness.settings.pauseSuggestions(for: .indefinitely)
        }
        harness.exchange.release(with: try instructionResponse("We will contact you tomorrow."))

        do {
            _ = try await task.value
            Issue.record("A response produced under an obsolete setting or app state must be discarded.")
        } catch is CancellationError {
            #expect(harness.exchange.requestCount == 1)
        }
    }

    private func expectCancellationWithoutRequest(
        _ harness: LearningExpressionServiceHarness,
        task: LearningExpressionTask,
        source: String
    ) async {
        do {
            _ = try await harness.service.generate(source: source, task: task)
            Issue.record("A disabled learning task must cancel before HTTP.")
        } catch is CancellationError {
            #expect(harness.exchange.requestCount == 0)
        } catch {
            Issue.record("Expected pre-request cancellation, received \(error).")
        }
    }

    private func makeHarness(
        translationEnabled: Bool = false,
        legacyAlignmentEnabled: Bool = false,
        sourceLanguages: [LearningLanguage] = [.chinese],
        targetLanguage: LearningLanguage = .english,
        legacyVocabularyEnabled: Bool = false,
        holdResponse: Bool = false,
        trackingEnabled: Bool = false,
        reply: LearningExpressionServiceReply = .translation,
        nextReply: LearningExpressionServiceReply? = nil
    ) throws -> LearningExpressionServiceHarness {
        let suiteName = "lingrove.test.learningExpressionService.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        if legacyVocabularyEnabled {
            defaults.set(true, forKey: "learningVocabularyEnabled")
            defaults.set(true, forKey: "learningTranslationVocabularyEnabled")
            defaults.set("apple banana", forKey: "learningVocabulary")
        }
        if legacyAlignmentEnabled {
            defaults.set(true, forKey: "learningAnalysisEnabled")
            defaults.set("endpoint", forKey: "learning.analysis.backend")
            defaults.set("legacy-alignment", forKey: "learning.analysis.endpointModel")
        }
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        settings.setGloballyEnabled(true)
        settings.setPerformanceTrackingEnabled(trackingEnabled)
        settings.languageLearning.translationEnabled = translationEnabled
        settings.languageLearning.model = "learning-instruction-model"
        settings.languageLearning.sourceLanguages = sourceLanguages
        settings.languageLearning.targetLanguage = targetLanguage

        let host = "\(UUID().uuidString.lowercased()).learning.invalid"
        settings.setOpenAICompatibleBaseURL("https://\(host)/v1")
        settings.languageLearning.translation.baseURL = "https://\(host)/v1"
        settings.setOpenAICompatibleModelName("completion-model")

        let exchange = LearningExpressionServiceExchange(automaticReply: holdResponse ? nil : reply, nextReply: nextReply)
        LearningExpressionServiceStubRegistry.register(exchange, for: host)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LearningExpressionServiceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenAICompatibleAPIClient(session: session)
        let metrics = PerformanceMetricsStore(userDefaults: defaults)
        let service = LearningExpressionService(settings: settings, client: client,
            telemetry: LearningRequestTelemetry(metrics: metrics,
                trackingEnabled: { settings.isPerformanceTrackingEnabled }))

        return LearningExpressionServiceHarness(
            settings: settings,
            service: service,
            metrics: metrics,
            exchange: exchange,
            session: session,
            defaults: defaults,
            suiteName: suiteName,
            host: host
        )
    }

    private func instructionPrompt(from request: CapturedLearningHTTPRequest) throws -> String {
        let data = try #require(request.body)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        return try #require(messages.last?["content"] as? String)
    }

    private func instructionResponse(_ content: String, finishReason: String = "stop") throws -> LearningExpressionServiceReply {
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": finishReason, "message": ["content": content]]]
        ])
        return LearningExpressionServiceReply(statusCode: 200, body: body)
    }
}

enum StaleLearningChange: String, CaseIterable, CustomStringConvertible, Sendable {
    case learningSettings
    case model
    case endpoint
    case credential
    case globalOptOut
    case temporaryPause

    var description: String { rawValue }
}

/// Each harness keeps its private preferences, endpoint session, and response exchange together.
/// Cleanup removes only that test's URLProtocol registration and suite.
@MainActor
private struct LearningExpressionServiceHarness {
    let settings: SuggestionSettingsModel
    let service: LearningExpressionService
    let metrics: PerformanceMetricsStore
    let exchange: LearningExpressionServiceExchange
    let session: URLSession
    let defaults: UserDefaults
    let suiteName: String
    let host: String

    func cleanUp() {
        LearningExpressionServiceStubRegistry.unregister(host: host)
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private struct CapturedLearningHTTPRequest: Sendable {
    let url: URL?
    let method: String?
    let headers: [String: String]
    let body: Data?
}

private struct LearningExpressionServiceReply {
    let statusCode: Int
    let body: Data

    static let translation = LearningExpressionServiceReply(
        statusCode: 200,
        body: Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"  We can meet tomorrow.  "}}]}"#.utf8)
    )

}

/// A lock protects request/continuation handoff because URLProtocol callbacks run away from the
/// main actor. The test controls when a held response is released to make each stale guard exact.
nonisolated private final class LearningExpressionServiceExchange: @unchecked Sendable {
    private let lock = NSLock()
    private let automaticReply: LearningExpressionServiceReply?
    private let nextReply: LearningExpressionServiceReply?
    private var requests: [CapturedLearningHTTPRequest] = []
    private var pendingReply: LearningExpressionServiceReply?
    private var capturedRequest: CapturedLearningHTTPRequest?
    private var observedRequestCount = 0
    private var requestWaiters: [Int: CheckedContinuation<CapturedLearningHTTPRequest, Never>] = [:]
    private var activeProtocol: LearningExpressionServiceURLProtocol?
    private var hasDeliveredReply = false

    init(automaticReply: LearningExpressionServiceReply?, nextReply: LearningExpressionServiceReply?) {
        self.automaticReply = automaticReply
        self.nextReply = nextReply
        pendingReply = automaticReply
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observedRequestCount
    }

    func waitForRequest(index: Int = 0) async -> CapturedLearningHTTPRequest {
        await withCheckedContinuation { continuation in
            lock.lock()
            if requests.indices.contains(index) {
                let request = requests[index]
                lock.unlock()
                continuation.resume(returning: request)
            } else {
                requestWaiters[index] = continuation
                lock.unlock()
            }
        }
    }

    func attach(
        protocolInstance: LearningExpressionServiceURLProtocol,
        request: CapturedLearningHTTPRequest
    ) {
        lock.lock()
        observedRequestCount += 1
        capturedRequest = request
        activeProtocol = protocolInstance
        let index = requests.count
        requests.append(request)
        let waiter = requestWaiters.removeValue(forKey: index)
        let reply = index == 0 ? pendingReply : nextReply
        let shouldDeliver = reply != nil && (index > 0 || !hasDeliveredReply)
        if shouldDeliver { hasDeliveredReply = true }
        lock.unlock()

        waiter?.resume(returning: request)
        if let reply, shouldDeliver {
            deliver(reply, to: protocolInstance, for: request)
        }
    }

    func release(with reply: LearningExpressionServiceReply) {
        lock.lock()
        pendingReply = reply
        let protocolInstance = activeProtocol
        let request = capturedRequest
        let shouldDeliver = protocolInstance != nil && request != nil && !hasDeliveredReply
        if shouldDeliver { hasDeliveredReply = true }
        lock.unlock()

        if shouldDeliver, let protocolInstance, let request {
            deliver(reply, to: protocolInstance, for: request)
        }
    }

    func stop(_ protocolInstance: LearningExpressionServiceURLProtocol) {
        lock.lock()
        if activeProtocol === protocolInstance { activeProtocol = nil }
        lock.unlock()
    }

    private func deliver(
        _ reply: LearningExpressionServiceReply,
        to protocolInstance: LearningExpressionServiceURLProtocol,
        for request: CapturedLearningHTTPRequest
    ) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: reply.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            protocolInstance.client?.urlProtocol(protocolInstance, didFailWithError: URLError(.badServerResponse))
            return
        }
        protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
        protocolInstance.client?.urlProtocol(protocolInstance, didLoad: reply.body)
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }
}

/// URLProtocol can consult this registry on a URLSession callback queue. Each test uses a distinct
/// synthetic host, and the lock protects only registration and lookup rather than model work.
nonisolated private enum LearningExpressionServiceStubRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var exchanges: [String: LearningExpressionServiceExchange] = [:]

    static func register(_ exchange: LearningExpressionServiceExchange, for host: String) {
        lock.lock()
        exchanges[host] = exchange
        lock.unlock()
    }

    static func exchange(for host: String) -> LearningExpressionServiceExchange? {
        lock.lock()
        defer { lock.unlock() }
        return exchanges[host]
    }

    static func unregister(host: String) {
        lock.lock()
        exchanges.removeValue(forKey: host)
        lock.unlock()
    }
}

/// Captures the request and routes it to the matching per-test exchange; it never opens a socket.
nonisolated private final class LearningExpressionServiceURLProtocol: URLProtocol {
    private var exchange: LearningExpressionServiceExchange?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".learning.invalid") == true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host,
              let exchange = LearningExpressionServiceStubRegistry.exchange(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        self.exchange = exchange
        exchange.attach(protocolInstance: self, request: Self.capture(request))
    }

    override func stopLoading() {
        exchange?.stop(self)
    }

    private static func capture(_ request: URLRequest) -> CapturedLearningHTTPRequest {
        CapturedLearningHTTPRequest(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: bodyData(from: request)
        )
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
