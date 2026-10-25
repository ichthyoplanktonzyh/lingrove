import Combine
import Foundation
import Testing
@testable import Lingrove

/// Exercises the shared staged session with a controllable service. Delayed replies make the
/// target and card lifetime observable without loading a model or reading a host editor.
@MainActor
struct LearningLookupSessionTests {
    @Test func openingQueriesOneBasicPairAndDetailsUseThatPairAcrossDictionaryTabs() async throws {
        let service = LookupSessionService()
        let session = LearningDictionarySession(provider: LookupSessionDictionary(), explanationService: service)
        defer { session.close() }
        let capture = capture(translationLanguage: .japanese)
        let unit = unit(for: capture)
        session.open(unit, documentID: UUID(), language: .english, speechContext: capture.example?.text,
            vocabularyCapture: capture, translationLanguage: .japanese)

        await wait { service.lookupCalls.count == 1 }
        #expect(service.detailCalls.isEmpty, "Opening the card requests only its compact meaning/translation pair")
        #expect(session.favoriteCapture == nil, "An initial in-flight request cannot save a pre-result capture")
        #expect(service.lookupCalls[0].translationLanguage == .japanese)
        #expect(service.lookupCalls[0].referenceTranslation == "進捗を随時知らせてください。")

        let basic = service.basic(for: service.lookupCalls[0])
        service.finishLookup(0)
        await wait { session.explanation.lookupRecord != nil }
        #expect(session.explanation.lookupRecord == basic)

        session.selectPage(.dictionary)
        await wait { session.content == .result(.notFound) }
        session.selectPage(.contextual)
        #expect(service.lookupCalls.count == 1, "Changing pages keeps the captured lookup session")

        session.explanation.toggleLookupDetails()
        await wait { service.detailCalls.count == 1 }
        #expect(service.detailCalls[0] == basic, "The detailed request receives the exact accepted basic record")
        service.finishDetails(0)
        await wait { session.explanation.record != nil }
        #expect(session.explanation.record?.result.meaning == basic.result.meaning)
        #expect(session.explanation.record?.input == basic.input.target)

        session.explanation.toggleLookupDetails()
        session.explanation.toggleLookupDetails()
        #expect(service.detailCalls.count == 1, "Reopening completed details does not rerun the model")
        #expect(session.explanation.lookupRecord == basic, "Details leave the accepted pair intact")
    }

    @Test func favoriteKeepsTheBasicMeaningTranslationPairAndTheirLanguages() async throws {
        let service = LookupSessionService()
        let session = LearningDictionarySession(provider: LookupSessionDictionary(), explanationService: service)
        defer { session.close() }
        let capture = capture(translationLanguage: .japanese)
        session.open(unit(for: capture), documentID: UUID(), language: .english,
            vocabularyCapture: capture, translationLanguage: .japanese)
        await wait { service.lookupCalls.count == 1 }
        service.finishLookup(0)
        await wait { session.explanation.lookupRecord != nil }

        let expected = try #require(session.explanation.lookupRecord)
        let favorite = try #require(session.favoriteCapture)
        #expect(!favorite.allowsExplanationEnrichment)
        #expect(favorite.meaning == expected.result.meaning)
        #expect(favorite.meaningLanguage == expected.language)
        #expect(favorite.example?.meaning == expected.result.meaning)
        #expect(favorite.example?.meaningLanguage == expected.language)
        #expect(favorite.example?.translation == expected.result.sentenceTranslation)
        #expect(favorite.example?.translationLanguage == expected.input.translationLanguage)
        #expect(favorite.example?.translationVariants.contains(.init(text: "進捗を随時知らせてください。", language: .japanese)) == true)
        #expect(service.detailCalls.isEmpty, "Saving the short pair does not require expanded details")
    }

    @Test(arguments: [true, false])
    func lookupTranslationLanguageUsesExplicitValueOrTheCapturedExample(_ explicit: Bool) async throws {
        let service = LookupSessionService()
        let session = LearningDictionarySession(provider: LookupSessionDictionary(), explanationService: service)
        defer { session.close() }
        let capture = capture(translationLanguage: .japanese)
        session.open(unit(for: capture), documentID: UUID(), language: .english,
            vocabularyCapture: capture, translationLanguage: explicit ? .spanish : nil)
        await wait { service.lookupCalls.count == 1 }

        #expect(service.lookupCalls[0].translationLanguage == (explicit ? .spanish : .japanese))
        service.finishLookup(0)
        await wait { session.explanation.lookupRecord != nil }
        let favorite = try #require(session.favoriteCapture)
        #expect(favorite.example?.translationLanguage == (explicit ? .spanish : .japanese))
    }

    @Test func replacingWordAndClosingRejectLateBasicAndDetailReplies() async throws {
        let service = LookupSessionService()
        let session = LearningDictionarySession(provider: LookupSessionDictionary(), explanationService: service)
        let capture = capture(expression: "look forward to", translationLanguage: .chinese)
        let expression = unit(for: capture)
        session.open(expression, documentID: UUID(), language: .english, speechContext: capture.example?.text,
            vocabularyCapture: capture)
        await wait { service.lookupCalls.count == 1 }

        let selectedWord = try #require(expression.words.first { $0.text == "forward" })
        session.select(selectedWord)
        await wait { service.lookupCalls.count == 2 }
        service.finishLookup(0)
        await Task.yield()
        #expect(session.explanation.lookupRecord == nil, "A response for the expression cannot enter the word session")
        #expect(session.explanation.lookupInput?.target.target == "forward")

        service.finishLookup(1)
        await wait { session.explanation.lookupRecord?.input.target.target == "forward" }
        session.explanation.toggleLookupDetails()
        await wait { service.detailCalls.count == 1 }
        session.close()
        service.finishDetails(0)
        await Task.yield()
        #expect(session.unit == nil && session.explanation.lookupRecord == nil && session.explanation.record == nil)
    }

    @Test func aSettingsChangeRejectsAnUncooperativeDetailReply() async throws {
        let service = LookupSessionService()
        let session = LearningDictionarySession(provider: LookupSessionDictionary(), explanationService: service)
        defer { session.close() }
        let capture = capture(translationLanguage: .chinese)
        session.open(unit(for: capture), documentID: UUID(), language: .english, vocabularyCapture: capture)
        await wait { service.lookupCalls.count == 1 }
        service.finishLookup(0)
        await wait { session.explanation.lookupRecord != nil }

        session.explanation.toggleLookupDetails()
        await wait { service.detailCalls.count == 1 }
        service.changed.send()
        service.finishDetails(0)
        await Task.yield()
        #expect(session.explanation.lookupRecord == nil && session.explanation.record == nil)
        #expect(!session.explanation.isGenerating && session.explanation.error == nil)
    }

    @Test func aRetiredReadingReceiptRejectsTheFinalBasicReply() async throws {
        let service = LookupSessionService()
        let session = LearningDictionarySession(provider: LookupSessionDictionary(), explanationService: service)
        defer { session.close() }
        let capture = capture(translationLanguage: .chinese)
        var receiptIsCurrent = true
        session.open(unit(for: capture), documentID: UUID(), language: .english, vocabularyCapture: capture,
            validateCapture: { receiptIsCurrent })
        await wait { service.lookupCalls.count == 1 }

        receiptIsCurrent = false
        service.finishLookup(0)
        await wait { session.explanation.lookupInput == nil }
        #expect(session.explanation.lookupRecord == nil && session.explanation.record == nil)
        #expect(service.displays == 0, "An invalidated reading receipt is never reported as displayed")
    }

    @Test func stoppingTheFirstStageRejectsItsReplyAndAFailedStageCanRetry() async throws {
        let service = LookupSessionService()
        let session = LearningDictionarySession(provider: LookupSessionDictionary(), explanationService: service)
        defer { session.close() }
        let capture = capture(translationLanguage: .chinese)
        session.open(unit(for: capture), documentID: UUID(), language: .english, vocabularyCapture: capture)
        await wait { service.lookupCalls.count == 1 }

        session.explanation.cancel()
        service.finishLookup(0)
        await Task.yield()
        #expect(session.explanation.lookupRecord == nil && !session.explanation.isGenerating)

        session.explanation.loadLookup()
        await wait { service.lookupCalls.count == 2 }
        service.failLookup(1)
        await wait { session.explanation.error != nil }
        #expect(session.explanation.lookupRecord == nil && !session.explanation.isGenerating)

        session.explanation.loadLookup(refresh: true)
        await wait { service.lookupCalls.count == 3 }
        service.finishLookup(2)
        await wait { session.explanation.lookupRecord != nil }
        #expect(session.explanation.error == nil)
    }

    private func capture(expression: String = "keep me posted", translationLanguage: LearningLanguage) -> VocabularyCapture {
        let sentence = expression == "look forward to" ? "We look forward to seeing you." : "Please keep me posted on progress."
        let phrase = (sentence as NSString).range(of: expression)
        var example = VocabularyPolicy.example(text: sentence, ranges: [phrase], language: .english)
        example?.translation = "進捗を随時知らせてください。"
        example?.translationLanguage = translationLanguage
        return .init(expression: expression, dictionaryForm: expression, language: .english,
            kind: .expression, example: example)
    }

    private func unit(for capture: VocabularyCapture) -> LearningUnit {
        let text = capture.example?.text ?? capture.expression
        let ranges = capture.example?.ranges.map(\.nsRange) ?? [NSRange(location: 0, length: capture.expression.utf16.count)]
        let words = LearningUnitPolicy.words(in: text, language: capture.language).filter { word in
            ranges.contains { NSIntersectionRange($0, word.range).length > 0 }
        }
        return .init(id: 0, surface: capture.expression, query: capture.dictionaryForm, kind: .expression,
            ranges: ranges, words: words)
    }

    private func wait(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(predicate(), "Timed out waiting for the staged lookup session")
    }
}

@MainActor
private final class LookupSessionService: LearningLookupGenerating {
    private struct PendingLookup {
        let input: LearningLookupInput
        let continuation: CheckedContinuation<LearningLookupRecord, any Error>
    }
    private struct PendingDetails {
        let record: LearningLookupRecord
        let continuation: CheckedContinuation<LearningExplanationRecord, any Error>
    }

    let changed = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    var language: LearningLanguage { .chinese }
    var isConfigured = true
    private(set) var lookupCalls: [LearningLookupInput] = []
    private(set) var detailCalls: [LearningLookupRecord] = []
    private(set) var legacyCalls = 0
    private(set) var displays = 0
    private let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var pendingLookups: [Int: PendingLookup] = [:]
    private var pendingDetails: [Int: PendingDetails] = [:]

    func lookup(_ input: LearningLookupInput, requestID: String, refresh: Bool) async throws -> LearningLookupRecord {
        lookupCalls.append(input)
        let index = lookupCalls.count - 1
        return try await withCheckedThrowingContinuation { pendingLookups[index] = .init(input: input, continuation: $0) }
    }

    func explainLookup(_ record: LearningLookupRecord, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        detailCalls.append(record)
        let index = detailCalls.count - 1
        return try await withCheckedThrowingContinuation { pendingDetails[index] = .init(record: record, continuation: $0) }
    }

    func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        legacyCalls += 1
        throw LearningFailure.message("The staged lookup should not use the legacy full explanation call.")
    }

    func loadSaved(for input: LearningExplanationInput) async -> LearningExplanationRecord? { nil }
    func savedRecord(for input: LearningExplanationInput) -> LearningExplanationRecord? { nil }
    func recordDisplay(requestID: String) { displays += 1 }

    func basic(for input: LearningLookupInput) -> LearningLookupRecord {
        .init(input: input, language: language,
            result: .init(meaning: "meaning for \(input.target.target)",
                sentenceTranslation: "translation in \(input.translationLanguage.rawValue)"),
            model: "fixture", createdAt: fixtureDate)
    }

    func finishLookup(_ index: Int) {
        guard let pending = pendingLookups.removeValue(forKey: index) else { return }
        pending.continuation.resume(returning: basic(for: pending.input))
    }

    func failLookup(_ index: Int) {
        guard let pending = pendingLookups.removeValue(forKey: index) else { return }
        pending.continuation.resume(throwing: NSError(domain: "lookup-fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The first lookup failed."]))
    }

    func finishDetails(_ index: Int) {
        guard let pending = pendingDetails.removeValue(forKey: index) else { return }
        pending.continuation.resume(returning: .init(id: UUID(), input: pending.record.input.target,
            language: pending.record.language,
            result: .init(meaning: pending.record.result.meaning, explanation: "Detailed usage for the accepted meaning."),
            model: pending.record.model, createdAt: Date()))
    }
}

private actor LookupSessionDictionary: LearningDictionaryProviding {
    func lookup(_ query: String, language: LearningLanguage, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        .notFound
    }
}
