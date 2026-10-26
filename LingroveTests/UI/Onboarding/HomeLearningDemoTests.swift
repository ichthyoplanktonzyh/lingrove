import Foundation
import Testing
@testable import Lingrove

/// The walkthrough calls the same sessions/stores as a live card. These tests validate its
/// action receipts and cancellation rather than asserting a second copy of its view hierarchy.
@Suite(.serialized)
@MainActor
struct HomeLearningDemoTests {
    @Test func expressionAssistanceUsesItsOwnBoundedSceneAndNeverChangesTheExampleDocument() {
        let model = HomeLearningDemoModel()
        defer { model.stop() }
        let original = model.editorText
        model.select(.expression)
        #expect(model.action == .expressionTrigger)
        #expect(model.scene.steps == [.expressionTrigger, .expressionDescribe, .expressionChoose, .expressionInsert])
        model.go(to: 3)
        #expect(model.action == .expressionInsert)
        #expect(model.editorText == original)
    }

    @Test func phraseAndComponentRangesKeepTheirOriginalSentence() throws {
        let fixture = HomeLearningDemoFixtures.capture
        let unit = HomeLearningDemoFixtures.unit
        for word in unit.words {
            let capture = try #require(VocabularyCaptureFactory.component(word, unit: unit, capture: fixture))
            let example = try #require(capture.example)
            let range = try #require(example.ranges.first)
            #expect((example.text as NSString).substring(with: range.nsRange) == word.text)
        }
        let sentence = VocabularyCapture(expression: HomeLearningDemoFixtures.translation,
            dictionaryForm: HomeLearningDemoFixtures.translation, language: .english, kind: .sentence)
        let explanation = HomeLearningDemoFixtures.record(LearningExplanationPolicy.input(sentence))
        #expect(explanation.result.meaning == HomeLearningDemoFixtures.source)
        #expect(explanation.result.meaning != HomeLearningDemoFixtures.meaning)
    }

    @Test func replaceChangesOnlyTheSavedSourceAndDismissPreservesTheResult() async throws {
        let model = HomeLearningDemoModel()
        defer { model.stop() }
        await model.prepare()
        model.go(to: try #require(model.scene.steps.firstIndex(of: .replace)))
        try await wait { model.presentation.canReplace }
        model.replace() // Same callback that the real ⇄ button uses, cancelling the scripted click.
        let result = model.editorText
        #expect(result == "谢谢你的帮助。" + HomeLearningDemoFixtures.translation + "我们下周再确认。")
        #expect(!model.presentation.canReplace)
        model.go(to: try #require(model.scene.steps.firstIndex(of: .dismiss)))
        try await wait { !model.cardVisible }
        #expect(model.editorText == result)
    }

    @Test func readingCapturesAreReadOnlyAndPointerKeepsItsSentence() async throws {
        let model = HomeLearningDemoModel()
        defer { model.stop() }
        await model.prepare()
        model.select(.reading)
        for source in LearningReadingSource.allCases {
            model.useReadingSource(source); model.showReadingTranslation()
            #expect(!model.presentation.canReplace)
            let before = model.editorText
            model.replace()
            #expect(model.editorText == before)
        }
        model.useReadingSource(.pointer)
        let capture = model.currentCapture
        #expect(capture.expression == "posted")
        #expect(capture.example?.text == HomeLearningDemoFixtures.translation)
        #expect(model.presentation.readingSource == .pointer)
        model.useReadingSource(.screenshot)
        #expect(model.presentation.source.contains("\n"))
        #expect(model.presentation.translation.contains("\n"))
    }

    @Test func jumpingToDictionaryWorksAndManualSourceChoiceRetiresTheTimer() async throws {
        let model = HomeLearningDemoModel()
        defer { model.stop() }
        await model.prepare()
        model.select(.lookup)
        model.go(to: try #require(model.scene.steps.firstIndex(of: .sources)))
        try await wait { model.dictionaryMenuPresented }
        #expect(model.lookupVisible)
        #expect(model.dictionary.unit != nil)
        #expect(model.dictionary.page == .dictionary)
        model.interact()
        model.dictionary.selectSource(.system)
        model.dictionaryMenuPresented = false
        try await Task.sleep(for: .seconds(2))
        #expect(model.dictionary.selectedSource == .system)
        model.dismissCard()
        #expect(model.dictionary.unit == nil)
        #expect(!model.lookupVisible)
    }

    @Test func favoriteMenuUsesTheSavedReceiptAndSceneSwitchCancelsIt() async throws {
        let model = HomeLearningDemoModel()
        defer { model.stop() }
        await model.prepare()
        model.go(to: try #require(model.scene.steps.firstIndex(of: .favoriteMenu)))
        try await wait { model.favoriteMenuPresented }
        let capture = model.currentCapture
        #expect(model.store.contains(capture))
        await model.store.remove(capture)
        #expect(!model.store.contains(capture))
        model.select(.speech)
        #expect(!model.favoriteMenuPresented)
        #expect(!model.isPlaying)
    }

    @Test func notebookContainsSeparateBankSensesAndGraphSelectsTheSameSense() async throws {
        let model = HomeLearningDemoModel()
        defer { model.stop() }
        await model.prepare()
        let bank = try #require(model.store.entries.first { $0.expression == "bank" })
        #expect(bank.senses.count == 2)
        model.select(.vocabulary)
        model.go(to: try #require(model.scene.steps.firstIndex(of: .headword)))
        try await wait { model.graph.expanded.contains(bank.id) }
        let snapshot = VocabularyGraphProjection.make(entries: model.store.entries, expanded: model.graph.expanded, query: "")
        #expect(snapshot.nodes.count >= model.store.entries.count + 2)
        let sense = try #require(bank.senses.first)
        model.selectSense(.init(entryID: bank.id, senseID: sense.id))
        #expect(model.selectedSense?.id == sense.id)
        #expect(model.selectedEntry?.id == bank.id)
    }

    @Test func hoverExitAndNativeLookupCancelPendingCardActions() async throws {
        let model = HomeLearningDemoModel()
        defer { model.stop() }
        await model.prepare()
        model.go(to: try #require(model.scene.steps.firstIndex(of: .replace)))
        model.play(hovered: true)
        model.hover(false, reduceMotion: false)
        let before = model.editorText
        try await Task.sleep(for: .seconds(1.7))
        #expect(model.editorText == before)
        #expect(!model.isPlaying)
        model.go(to: try #require(model.scene.steps.firstIndex(of: .dismiss)))
        model.openLookup()
        try await Task.sleep(for: .seconds(1.7))
        #expect(model.lookupVisible)
        #expect(model.dictionary.unit != nil)
    }

    @Test func ankiRemainsUsableAfterFavoritingBeforeAnExplanationIsReady() async throws {
        let model = HomeLearningDemoModel()
        defer { model.stop() }
        let early = try #require(VocabularyCaptureFactory.unit(HomeLearningDemoFixtures.unit, in: model.presentation))
        #expect(early.example?.meaning.isEmpty == true)
        await model.store.save(early)
        await model.prepareReview()
        let session = try #require(model.ankiSession)
        #expect(session.validationMessage == nil)
        let example = session.current?.sense.examples.first { $0.id == session.plan.exampleID }
        #expect(example?.meaning.isEmpty == false)
        #expect(await session.send())
    }

    @Test func ankiUsesRealSerializationAndCanUpdateThenOpenItsSavedDeck() async throws {
        let model = HomeLearningDemoModel()
        defer { model.stop() }
        await model.prepareReview()
        let session = try #require(model.ankiSession)
        #expect(session.validationMessage == nil)
        #expect(session.plan.layout != nil)
        await model.sendCard()
        let id = try #require(session.binding?.noteID, Comment(rawValue: session.message ?? "Missing Anki receipt"))
        #expect(id > 0)
        #expect(session.binding?.fields["Front"]?.contains(session.current?.entry.expression ?? "missing") == true)
        session.plan.name = "Example card"
        await model.sendCard()
        #expect(session.binding?.noteID == id)
        await model.reviewCard()
        #expect(model.ankiDestinationShown)
        #expect(model.reviewFailure == nil)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), "The current step must reach a visible result")
    }
}
