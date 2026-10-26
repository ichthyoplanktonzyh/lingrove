import AppKit
import Foundation
import Testing
@testable import Lingrove

/// A lookup-capable presenter proves the new entry routing without real AX access or model
/// downloads. The retained receipt guard is driven after presentation like a delayed model reply.
@MainActor
struct LearningReadingLookupTests {
    @Test(arguments: [LearningLanguage.chinese, .english])
    func aPartialSelectionOpensTheExistingLookupWithoutCallingTranslation(_ target: LearningLanguage) async throws {
        let rig = try Rig(text: "bank", context: "He sat on the bank of the river.", target: target)
        defer { rig.close() }
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await wait { rig.panel.lookup != nil }
        #expect(rig.service.calls == 0 && rig.panel.sentence == nil)
        #expect(rig.panel.lookup?.capture.expression == "bank")
        #expect(rig.panel.lookup?.capture.example?.text == "He sat on the bank of the river.")
        #expect(rig.panel.lookup?.translationLanguage == target)
        #expect(rig.panel.validate?() == true)
        rig.panel.inside = true
        rig.coordinator.handlePointerEvent(type: .leftMouseDown, at: .zero, clickCount: 1)
        #expect(rig.coordinator.isActive)
        rig.reader.current = false
        #expect(rig.panel.validate?() == false)
        #expect(!rig.coordinator.isActive && !rig.panel.isVisible)
    }

    @Test func aCompleteSentenceStillUsesTheTranslationService() async throws {
        let rig = try Rig(text: "He sat on the bank of the river.", context: "He sat on the bank of the river.")
        defer { rig.close() }
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await wait { rig.panel.sentence != nil }
        #expect(rig.service.calls == 1 && rig.panel.lookup == nil)
        #expect(rig.panel.sentence?.translation == "他坐在河岸上。")
    }

    @Test func enrichmentReachesTheExistingLookupOnceBeforeAnyTranslation() async throws {
        let rig = try Rig(text: "history", context: "your review history.")
        defer { rig.close() }
        rig.reader.enrichedContext = "Preview cards and send notes to Anki Desktop while preserving your review history."
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await wait { rig.panel.lookup != nil }
        #expect(rig.reader.enrichments == 1 && rig.panel.lookupCalls == 1)
        #expect(rig.panel.lookup?.capture.expression == "history")
        #expect(rig.panel.lookup?.capture.example?.text == rig.reader.enrichedContext)
        #expect(rig.service.calls == 0 && rig.panel.sentence == nil)
    }

    @Test(arguments: [LearningLanguage.chinese, .english])
    func aSharedWordUsesItsSentenceWithoutALanguageHint(_ target: LearningLanguage) async throws {
        let rig = try Rig(text: "focus", context:
            "Listen to sentences or expressions without losing typing focus using macOS system voices.", target: target)
        defer { rig.close() }
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await wait { rig.panel.lookup != nil }
        #expect(rig.panel.lookup?.capture.language == .english)
        #expect(rig.panel.lookup?.capture.expression == "focus")
        #expect(rig.service.calls == 0 && rig.panel.sentence == nil)
    }

    @Test func ambiguousTechnicalWordStillOpensLookupWithItsCapturedContext() async throws {
        let rig = try Rig(text: "compatible", context: "OpenAI-compatible chat endpoint")
        defer { rig.close() }
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await wait { rig.panel.lookup != nil }
        let capture = try #require(rig.panel.lookup?.capture)
        #expect(capture.expression == "compatible")
        #expect(capture.example?.text == "OpenAI-compatible chat endpoint")
        #expect(rig.service.calls == 0)
    }

    @Test func wholeTechnicalCellStillReachesTranslationWhenItsLanguageIsUncertain() async throws {
        let text = "OpenAI-compatible chat endpoint"
        let rig = try Rig(text: text, context: text)
        defer { rig.close() }
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await wait { rig.panel.sentence?.translation.isEmpty == false }
        #expect(rig.service.calls == 1 && rig.panel.lookup == nil)
    }

    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<300 where !predicate() { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(predicate())
    }
    @MainActor private final class Rig {
        let name = "lingrove.test.reading.lookup.\(UUID())"
        let defaults: UserDefaults
        let service: SentenceService
        let reader: Reader
        let panel = LookupPanel()
        let coordinator: LearningReadingCoordinator
        let shortcut: InputMonitorKeyEvent
        init(text: String, context: String, target: LearningLanguage = .chinese) throws {
            defaults = try #require(UserDefaults(suiteName: name))
            let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
            settings.languageLearning.translationEnabled = true
            settings.languageLearning.selectionTranslationEnabled = true
            settings.languageLearning.readingTargetLanguage = target
            settings.updatePerAppTranslationPolicy(bundleIdentifier: "lookup.fixture", displayName: "Fixture") {
                $0.selectionTranslationAllowed = true
            }
            service = SentenceService(settings: settings)
            reader = Reader(text: text, context: context)
            coordinator = LearningReadingCoordinator(service: service, reader: reader, panel: panel,
                frontmostBundle: { "lookup.fixture" }, observesSystemEvents: false)
            let binding = settings.languageLearning.readingBinding(.selection)
            shortcut = .init(keyCode: binding.key, flags: [.maskAlternate, .maskShift])
            coordinator.start()
        }
        func close() { coordinator.stop(); defaults.removePersistentDomain(forName: name) }
    }
    private final class Reader: LearningReadingSelecting {
        var current = true
        var enrichedContext: String?
        var enrichments = 0
        let text: String, context: String
        init(text: String, context: String) { self.text = text; self.context = context }
        func capture() async throws -> LearningReadingSelection {
            .init(id: UUID(), text: text, processIdentifier: 1, bundleIdentifier: "lookup.fixture", anchor: .zero,
                context: LearningReadingContextPolicy.resolve(.init(text: context,
                    target: (context as NSString).range(of: text), left: .container, right: .container,
                    method: .characters), expected: text))
        }
        func isCurrent(_ capture: LearningReadingSelection) -> Bool { current }
        func enrich(_ capture: LearningReadingSelection) async throws -> LearningReadingSelection {
            enrichments += 1
            guard let enrichedContext else { return capture }
            var enriched = capture
            enriched.context = LearningReadingContextPolicy.resolve(.init(text: enrichedContext,
                target: (enrichedContext as NSString).range(of: text), left: .crop, right: .crop,
                method: .selectionOCR), expected: text)
            return enriched
        }
        func forget() {}
    }
    private final class SentenceService: LearningSentenceGenerating {
        let settings: SuggestionSettingsModel
        var calls = 0
        init(settings: SuggestionSettingsModel) { self.settings = settings }
        func translateSentence(source: String, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage) async throws -> String {
            calls += 1; return "他坐在河岸上。"
        }
        func recordDisplay(source: ModelRequestSource, requestID: String) {}
    }
    private final class LookupPanel: LearningSentencePresenting, LearningLookupPresenting {
        var isVisible = false, inside = false
        var lookup: LearningLookupPresentation?
        var lookupCalls = 0
        var sentence: LearningSentencePresentation?
        var validate: (() -> Bool)?
        func showLookup(_ presentation: LearningLookupPresentation, validate: @escaping () -> Bool, dismiss: @escaping () -> Void) {
            lookupCalls += 1; lookup = presentation; self.validate = validate; isVisible = true
        }
        func toggleLookupDetails() {}
        func containsGlobalInteraction(at point: CGPoint) -> Bool { inside }
        func show(_ presentation: LearningSentencePresentation, expand: @escaping () -> Void, dismiss: @escaping () -> Void) {
            sentence = presentation; isVisible = true
        }
        func hide() { isVisible = false }
    }
}
