import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import Testing
@testable import Lingrove

/// Controllable streamed updates verify user-visible ordering and stale rejection independently
/// from model speed. Synthetic AX handles are never queried or written by these collaborators.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LearningSentencePreviewCoordinatorTests {
    @Test
    func explicitInputHoldStopsADebouncedTranslationAndResumesOnTheNextEdit() async throws {
        let pause = PauseGate(), rig = try Rig(pause: pause)
        defer { rig.cleanup() }
        var held = false
        rig.coordinator.isReadingActive = { held }
        rig.coordinator.start()
        try rig.edit("你好")
        await waitUntil { pause.pending.count == 1 }
        held = true
        pause.release(0)
        for _ in 0..<10 { await Task.yield() }
        #expect(rig.service.requests.isEmpty && !rig.panel.isVisible)
        held = false
        try rig.edit("你好，很高兴认识你")
        await waitUntil { pause.pending.count == 2 }
        pause.release(1)
        await waitUntil { rig.service.requests.count == 1 }
    }

    @Test
    func translationContinuesWhileCompletionIsDisabledAndDoesNotChangeItsGate() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.settings.setCompletionEnabled(false)
        rig.coordinator.start()
        try rig.edit("你好，很高兴认识你。")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("Hello, nice to meet you.")
        await waitUntil { rig.panel.last?.translation == "Hello, nice to meet you." }
        #expect(rig.panel.isVisible)
        #expect(!rig.settings.isCompletionEnabled)
        #expect(rig.settings.languageLearning.translationEnabled)
    }

    @Test
    func deletingTheSentenceTailRetranslatesAfterTheSamePauseAndCanRestoreACachedPrefix() async throws {
        let pause = PauseGate(), rig = try Rig(pause: pause)
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("你好")
        await waitUntil { pause.pending.count == 1 }
        pause.release(0)
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("Hello.")
        await waitUntil { rig.panel.last?.translation == "Hello." }
        try rig.edit("你好，很高兴见到你")
        await waitUntil { pause.pending.count == 2 }
        pause.release(1)
        await waitUntil { rig.service.requests.count == 2 }
        rig.service.emit("Hello, nice to meet you.")
        await waitUntil { rig.panel.last?.translation == "Hello, nice to meet you." }

        #expect(!rig.coordinator.observe(.init(kind: .textMutation, keyCode: 51, characters: "", flags: [])))
        #expect(!rig.panel.isVisible)
        try rig.edit("你好，很高兴见到")
        await waitUntil { pause.pending.count == 3 }
        try rig.edit("你好，很高兴")
        await waitUntil { pause.pending.count == 4 }
        pause.release(2)
        for _ in 0..<10 { await Task.yield() }
        #expect(rig.service.requests.count == 2 && !rig.panel.isVisible)
        pause.release(3)
        await waitUntil { rig.service.requests.count == 3 }
        #expect(rig.service.requests.last?.source == "你好，很高兴")
        rig.service.translationCallbacks[2]("Hello")
        #expect(rig.panel.isVisible && rig.panel.last?.isTranslating == true && rig.panel.last?.canReplace == false)
        rig.service.emit("Hello, I'm happy.")
        await waitUntil { rig.panel.last?.canReplace == true }

        try rig.edit("你好")
        await waitUntil { pause.pending.count == 5 }
        #expect(!rig.panel.isVisible)
        pause.release(4)
        await waitUntil { rig.panel.isVisible && rig.panel.last?.translation == "Hello." }
        #expect(rig.service.requests.count == 3, "A deletion back to a validated cached source still reopens its translation")
        try rig.edit("")
        await waitUntil { pause.pending.count == 6 }
        pause.release(5)
        for _ in 0..<10 { await Task.yield() }
        #expect(!rig.panel.isVisible && rig.service.requests.count == 3, "Deleting the whole sentence leaves no translatable target")
        #expect(pause.durations.allSatisfy { $0 == .milliseconds(600) })
    }

    @Test
    func anUnfinishedStreamCannotBecomeThePreviousSentenceTranslation() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到。")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.translationCallbacks[0]("I can")
        try rig.edit("我能做到。明天开始。")
        await waitUntil { rig.service.requests.count == 2 }
        rig.service.emit("I will start tomorrow.")
        await waitUntil { rig.panel.isVisible && rig.panel.last?.translation == "I will start tomorrow." }
        #expect(rig.panel.last?.previousTranslation == nil)
    }

    @Test
    func partialTranslationAppearsImmediatelyButCannotBeReplaced() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        #expect(!rig.panel.isVisible)
        let partial = try #require(rig.service.translationCallbacks.first)
        partial("I can")
        #expect(rig.panel.isVisible && rig.panel.last?.translation == "I can")
        #expect(rig.panel.last?.isTranslating == true && rig.panel.last?.canReplace == false)
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: [.maskControl, .maskAlternate])) == .notHandled)
        rig.panel.replace?()
        await Task.yield()
        #expect(rig.reader.replaceCount == 0)
        for _ in 0..<10 { await Task.yield() }
        partial("I can do it.")
        #expect(rig.panel.last?.canReplace == false, "The final-looking prefix is still unvalidated")
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.canReplace == true }
        #expect(rig.panel.last?.isTranslating == false)
    }

    @Test
    func failedStreamWithdrawsPartialTextAndLatePrefixesCannotReopenIt() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        let old = try #require(rig.service.translationCallbacks.first)
        old("I can")
        rig.service.failTranslation()
        await waitUntil { rig.panel.last?.isError == true }
        #expect(rig.panel.last?.translation.isEmpty == true && rig.panel.last?.canReplace == false)
        old("Late fragment")
        #expect(rig.panel.last?.isError == true && rig.panel.last?.translation.isEmpty == true)
        try rig.edit("我可以做更多")
        await waitUntil { rig.service.requests.count == 2 }
        old("I can do it.")
        #expect(!rig.panel.isVisible)
        let current = try #require(rig.service.translationCallbacks.last)
        current("I can do more")
        #expect(rig.panel.last?.translation == "I can do more")
        _ = rig.coordinator.observe(.init(kind: .textMutation, keyCode: 0, characters: "a", flags: []))
        current("I can do more things.")
        #expect(!rig.panel.isVisible, "Typing invalidates even already scheduled partial callbacks")
    }

    @Test(arguments: [false, true])
    func movingTheEditorReanchorsTheExistingTranslationWithoutGeneratingAgain(_ publishesBeforeStorage: Bool) async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("很高兴认识你")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("Nice to meet you.")
        await waitUntil { rig.panel.last?.translation == "Nice to meet you." }
        let identifier = try #require(rig.panel.last?.id)
        let movedCaret = CGRect(x: 350, y: 700, width: 2, height: 18)
        try rig.edit("很高兴认识你", caret: movedCaret, publishesBeforeStorage: publishesBeforeStorage)
        #expect(rig.panel.last?.caret == movedCaret,
            "Scrolling or moving a window must move the card even when the source text has not changed")
        #expect(rig.panel.last?.id == identifier && rig.panel.last?.translation == "Nice to meet you.")
        #expect(rig.service.requests.count == 1)
        #expect(rig.reader.replaceCount == 0)
        let shown = rig.panel.showCount
        try rig.edit("很高兴认识你", caret: movedCaret)
        #expect(rig.panel.showCount == shown, "An unchanged focus poll must not rebuild the card")
        _ = rig.coordinator.observe(.init(kind: .textMutation, keyCode: 1, characters: "s", flags: []))
        try rig.edit("很高兴认识你", caret: movedCaret.offsetBy(dx: 0, dy: -100))
        #expect(!rig.panel.isVisible, "Geometry updates must not reopen a preview hidden by typing")
    }

    @Test
    func searchFieldRequiresAnExplicitLearningShortcut() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到", capability: .blocked(SearchFieldDetector.blockedReason))
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.service.requests.isEmpty)
        #expect(!rig.panel.isVisible)

        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        await waitUntil { rig.service.requests.count == 1 }
        #expect(rig.service.requests.first?.source == "我能做到")
    }

    @Test
    func searchRestrictionArrivingDuringThePauseStopsAutomaticLearning() async throws {
        let pause = PauseGate(), rig = try Rig(pause: pause)
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { pause.pending.count == 1 }
        let snapshot = rig.focus.snapshot
        rig.focus.snapshot = FocusSnapshot(applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier, capability: .blocked(SearchFieldDetector.blockedReason),
            context: snapshot.context)
        pause.release(0)
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.service.requests.isEmpty)
        #expect(!rig.panel.isVisible)
    }

    @Test
    func searchReclassificationWithdrawsAPassivePreviewWithoutATextEdit() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        let snapshot = rig.focus.snapshot
        rig.focus.snapshot = FocusSnapshot(applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier, capability: .blocked(SearchFieldDetector.blockedReason),
            context: snapshot.context)
        rig.focus.snapshotSubject.send(rig.focus.snapshot)
        #expect(!rig.panel.isVisible)
        #expect(rig.reader.replaceCount == 0)

        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        await waitUntil { rig.service.requests.count == 2 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.isVisible && rig.panel.last?.translation == "I can do it." }
        rig.focus.snapshotSubject.send(rig.focus.snapshot)
        #expect(rig.panel.isVisible, "An explicitly requested preview survives an unchanged search snapshot.")
    }

    @Test
    func translationAndWordLookupSurviveIndependentUnitRecognition() async throws {
        let gate = UnitGate(), rig = try Rig(unitRecognizer: gate)
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我期待见到你")
        await waitUntil { rig.service.requests.count == 1 }
        let text = "I look forward to seeing you."
        rig.service.emit(text)
        await gate.waitFor(text)
        #expect(rig.panel.last?.translation == text && rig.panel.isVisible)
        #expect(rig.panel.last?.unitStage == .pending)
        #expect(rig.panel.last?.message.isEmpty == true, "Disabled optional alignment must not add an explanatory row")
        let unit = LearningUnit(id: 2, surface: "look forward to", query: "look forward to", kind: .expression,
            ranges: [.init(location: 2, length: 15)], words: [])
        await gate.finish(text, units: [unit])
        await waitUntil { rig.panel.last?.unitStage == .ready }
        #expect(rig.panel.last?.units == [unit])
        #expect(rig.reader.replaceCount == 0)
    }

    @Test
    func staleRecognitionCannotReopenAPreviewAfterTyping() async throws {
        let gate = UnitGate(), rig = try Rig(unitRecognizer: gate)
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我期待见到你")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I look forward to seeing you.")
        await gate.waitFor("I look forward to seeing you.")
        _ = rig.coordinator.observe(.init(kind: .textMutation, keyCode: 1, characters: "s", flags: []))
        #expect(!rig.panel.isVisible)
        await gate.finish("I look forward to seeing you.", units: [])
        for _ in 0..<20 { await Task.yield() }
        #expect(!rig.panel.isVisible)
    }

    @Test
    func failedUnitResourceKeepsTheFixedTranslationAvailable() async throws {
        let rig = try Rig(unitRecognizer: LearningLexiconService(resourceURL: nil))
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我期待见到你")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I look forward to seeing you.")
        await waitUntil { rig.panel.last?.unitStage == .failed }
        #expect(rig.panel.isVisible && rig.panel.last?.translation == "I look forward to seeing you.")
        #expect(rig.panel.last?.units.isEmpty == true)
    }

    @Test
    func typingHidesImmediatelyAndOnlyTheLatestPauseCanPresent() async throws {
        let pause = PauseGate(), rig = try Rig(pause: pause)
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { pause.pending.count == 1 }
        #expect(!rig.panel.isVisible && rig.service.requests.isEmpty)
        pause.release(0)
        await waitUntil { rig.service.requests.count == 1 }
        #expect(!rig.panel.isVisible, "Finishing the input pause starts translation without showing a loading card")
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.isGenerating == false }
        let oldCallback = try #require(rig.service.translationCallbacks.first)
        #expect(rig.panel.isVisible)
        #expect(!rig.coordinator.observe(.init(kind: .textMutation, keyCode: 0, characters: "a", flags: [])))
        #expect(!rig.panel.isVisible, "Keyboard input must hide before AX catches up")
        let shown = rig.panel.showCount
        oldCallback("Late prefix")
        #expect(!rig.panel.isVisible && rig.panel.showCount == shown)
        try rig.edit("我能做到更多")
        await waitUntil { pause.pending.count == 2 }
        try rig.edit("我能做到更多事情")
        await waitUntil { pause.pending.count == 3 }
        #expect(!rig.panel.isVisible && rig.service.requests.count == 1)
        pause.release(1)
        await Task.yield()
        #expect(!rig.panel.isVisible && rig.service.requests.count == 1)
        pause.release(2)
        await waitUntil { rig.service.requests.count == 2 }
        #expect(!rig.panel.isVisible)
        rig.service.emit("I can do more things.")
        await waitUntil { rig.panel.last?.translation == "I can do more things." }
        #expect(rig.panel.isVisible)
        #expect(rig.panel.last?.source == "我能做到更多事情")
        #expect(pause.durations.allSatisfy { $0 == .milliseconds(600) })
    }

    @Test
    func cachedPreviewAlsoWaitsForPause() async throws {
        let pause = PauseGate(), rig = try Rig(pause: pause)
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { pause.pending.count == 1 }
        pause.release(0)
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.isGenerating == false }
        await waitUntil { rig.panel.last?.isGenerating == false }
        try rig.edit("你能做到")
        await waitUntil { pause.pending.count == 2 }
        pause.release(1)
        await waitUntil { rig.service.requests.count == 2 }
        try rig.edit("我能做到")
        await waitUntil { pause.pending.count == 3 }
        #expect(!rig.panel.isVisible)
        pause.release(2)
        await waitUntil { rig.panel.isVisible && rig.panel.last?.translation == "I can do it." }
        #expect(rig.service.requests.count == 2)
    }

    @Test
    func explicitShortcutCanReopenAfterInputSuspendsThePreview() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.isGenerating == false }
        await waitUntil { rig.panel.last?.isGenerating == false }
        _ = rig.coordinator.observe(.init(kind: .navigation, keyCode: 123, characters: "", flags: []))
        #expect(!rig.panel.isVisible)
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        await waitUntil { rig.panel.isVisible && rig.panel.last?.isExpanded == true }
        #expect(rig.panel.last?.isStale == false)
        #expect(rig.service.requests.count == 1)
    }

    @Test
    func editingCancelsTheActiveTranslation() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        try rig.edit("我能做到更多")
        await waitUntil { rig.service.cancelledTranslation == 1 }
        await waitUntil { rig.service.requests.count == 2 }
        #expect(rig.service.requests.last?.source == "我能做到更多")
    }

    @Test
    func lowPowerPauseCancelsTranslationAndRequiresANewEdit() async throws {
        var paused = false
        let rig = try Rig(availability: { paused ? "Paused in Low Power Mode" : nil })
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        paused = true
        rig.coordinator.availabilityChanged()
        await waitUntil { rig.service.cancelledTranslation == 1 }
        #expect(!rig.panel.isVisible)
        paused = false
        await Task.yield()
        #expect(rig.service.requests.count == 1)
        try rig.edit("我能做到更多")
        await waitUntil { rig.service.requests.count == 2 }
    }

    @Test
    func focusEntryDoesNotSendExistingText() async throws {
        let rig = try Rig(initial: "已有内容")
        defer { rig.cleanup() }
        rig.coordinator.start()
        await Task.yield()
        #expect(rig.service.requests.isEmpty)
        #expect(!rig.panel.isVisible)
    }

    @Test
    func completedTranslationKeepsTypingKeysUnclaimed() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        #expect(rig.panel.last?.translation == "I can do it.")
        #expect(rig.panel.last?.isExpanded == false)
        #expect(rig.coordinator.decide(.init(keyCode: 36, flags: [])) == .notHandled)
        #expect(rig.coordinator.decide(.init(keyCode: 48, flags: [])) == .notHandled)
        await waitUntil { rig.panel.last?.isGenerating == false }
        #expect(rig.reader.replaceCount == 0)
    }

    @Test(arguments: [false, true])
    func escapeClosesTheChildBeforeTheSentencePair(_ becomesUnavailable: Bool) async throws {
        var eligible = true
        let rig = try Rig(availability: { eligible ? nil : "unavailable" })
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        rig.panel.hasDetail = true
        eligible = !becomesUnavailable
        #expect(rig.coordinator.decide(.init(keyCode: 53, flags: [])) == .consume)
        #expect(rig.panel.isVisible)
        #expect(!rig.panel.hasDetail)
        #expect(rig.coordinator.decide(.init(keyCode: 53, flags: [])) == .consume)
        #expect(!rig.panel.isVisible)
    }

    @Test
    func expandingUsesAlreadyGeneratedTranslation() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        await waitUntil { rig.panel.last?.isGenerating == false }
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        await waitUntil { rig.panel.last?.isExpanded == true }
        #expect(rig.service.requests.count == 1)
    }

    @Test
    func aNewSentenceRetainsPreviousTranslationAndOnlySendsCurrentSentence() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我喜欢你")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I like you.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        await waitUntil { rig.panel.last?.isGenerating == false }
        try rig.edit("我喜欢你。我想多了解你")
        await waitUntil { rig.service.requests.count == 2 }
        #expect(rig.service.requests[1].source == "我想多了解你")
        #expect(!rig.panel.isVisible)
        rig.service.emit("I want to know you better.")
        await waitUntil { rig.panel.last?.translation == "I want to know you better." }
        #expect(rig.panel.last?.previousTranslation == "I like you.")
    }

    @Test
    func appendingToUnfinishedSentenceReplacesThatSentence() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我喜欢你")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I like you.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        try rig.edit("我喜欢你做的饭")
        #expect(!rig.panel.isVisible)
        await waitUntil { rig.service.requests.count == 2 }
        #expect(rig.service.requests[1].source == "我喜欢你做的饭")
        #expect(rig.panel.last?.previousTranslation == nil)
        rig.service.emit("stale translation", request: 0)
        #expect(rig.panel.last?.translation != "stale translation")
    }

    @Test(arguments: ["disable", "endpoint", "focus", "stop"])
    func oldEventsCannotReopenAfterInvalidation(_ change: String) async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        switch change {
        case "disable": rig.settings.languageLearning.translationEnabled = false
        case "endpoint": rig.settings.languageLearning.translation.baseURL = "https://another.invalid/v1"
        case "focus": try rig.edit("另一字段", element: "other-field")
        default: rig.coordinator.stop()
        }
        rig.service.emit("obsolete")
        await Task.yield()
        #expect(!rig.panel.isVisible)
        #expect(rig.reader.replaceCount == 0)
    }

    @Test
    func editingEarlierTextDoesNotUseItsOldTranslationAsThePreviousSentence() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我喜欢你")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I like you.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        await waitUntil { rig.panel.last?.isGenerating == false }
        try rig.edit("我喜欢你。我想多了解你")
        await waitUntil { rig.service.requests.count == 2 }
        rig.service.emit("I'd like to know you better.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        await waitUntil { rig.panel.last?.isGenerating == false }
        try rig.edit("我喜欢你做的饭")
        await waitUntil { rig.service.requests.count == 3 }
        #expect(!rig.panel.isVisible)
        rig.service.emit("I like the food you cooked.")
        await waitUntil { rig.panel.last?.translation == "I like the food you cooked." }
        #expect(rig.panel.last?.previousTranslation == nil)
    }

    @Test
    func queuedShortcutCannotRunAfterStop() async throws {
        let rig = try Rig(initial: "我能做到")
        defer { rig.cleanup() }
        rig.coordinator.start()
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        rig.coordinator.stop()
        await Task.yield()
        #expect(rig.service.requests.isEmpty)
        #expect(!rig.panel.isVisible)
    }

    @Test
    func frontmostChangeRejectsUpdatesBeforeTheNextFocusSnapshot() async throws {
        var frontmost = true
        let rig = try Rig(isFrontmost: { frontmost })
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        frontmost = false
        rig.service.emit("I can do it.")
        await Task.yield()
        await Task.yield()
        #expect(!rig.panel.isVisible)
        #expect(rig.panel.showCount == 0, "Neither pending work nor a late translation may open the card in another app")
    }

    @Test
    func failedTranslationShowsItsErrorWithoutAnEarlierLoadingCard() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        #expect(!rig.panel.isVisible && rig.panel.showCount == 0)
        rig.service.failTranslation()
        await waitUntil { rig.panel.last?.isError == true }
        #expect(rig.panel.isVisible)
        #expect(rig.panel.last?.message == "translation unavailable")
        #expect(rig.panel.last?.isGenerating == false)
    }

    @Test
    func knownMarkedTextDoesNotGenerate() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到", marked: NSRange(location: 0, length: 4))
        await Task.yield()
        #expect(rig.service.requests.isEmpty)
        try rig.edit("我能做到", marked: nil)
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        await waitUntil { rig.panel.last?.isGenerating == false }
        #expect(rig.panel.last?.translation == "I can do it.")
    }

    @Test
    func explicitPreviewStillUsesTheSameCardWithAutomaticPreviewOff() async throws {
        let rig = try Rig(initial: "我能做到")
        defer { rig.cleanup() }
        rig.settings.languageLearning.sentencePreviewEnabled = false
        rig.coordinator.start()
        try rig.edit("我能做到更多")
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.service.requests.isEmpty && !rig.panel.isVisible)
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do more.")
        await waitUntil { rig.panel.last?.translation == "I can do more." }
        #expect(rig.panel.last?.isExpanded == true)
        #expect(rig.reader.replaceCount == 0)
    }

    @Test
    func confirmedReplacementClickAndShortcutWriteOnce() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.canReplace == true }
        #expect(rig.coordinator.decide(.init(keyCode: 36, flags: [])) == .notHandled)
        #expect(rig.coordinator.decide(.init(keyCode: 48, flags: [])) == .notHandled)
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: [.maskAlternate, .maskControl])) == .consume)
        rig.panel.replace?()
        await waitUntil { rig.reader.replaceCount == 1 }
        #expect(rig.reader.replaced?.source == "我能做到")
        #expect(rig.reader.replacementText == "I can do it.")
        await waitUntil { !rig.panel.isVisible }
    }

    @Test
    func appPolicyPassesBothWritingChordsThroughAndReenablingAllowsKeyboardReplacement() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.canReplace == true }
        let bundle = try #require(rig.focus.snapshot.bundleIdentifier)
        rig.settings.updatePerAppTranslationPolicy(bundleIdentifier: bundle, displayName: "Test") {
            $0.writingTranslationShortcutsAllowed = false
        }
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: [.maskAlternate, .maskControl])) == .notHandled)
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .notHandled)
        #expect(rig.reader.replaceCount == 0)
        rig.settings.updatePerAppTranslationPolicy(bundleIdentifier: bundle, displayName: "Test") {
            $0.writingTranslationShortcutsAllowed = true
        }
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: [.maskAlternate, .maskControl])) == .consume)
        await waitUntil { rig.reader.replaceCount == 1 }
        #expect(rig.reader.replacementText == "I can do it.")
    }

    @Test
    func selectedPreviewReplacesOnlyTheSavedSelectionAndStaleClickCannotWrite() async throws {
        let rig = try Rig(initial: "前文。我的目标。后文。", selection: ("前文。我的目标。后文。" as NSString).range(of: "我的目标"))
        defer { rig.cleanup() }
        rig.settings.languageLearning.referenceMode = .draft
        rig.coordinator.start()
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        await waitUntil { rig.service.requests.count == 1 }
        #expect(rig.service.inputs.first?.referenceBefore == "前文。")
        #expect(rig.service.inputs.first?.referenceAfter == "。后文。")
        rig.service.emit("my goal")
        await waitUntil { rig.panel.last?.canReplace == true }
        #expect(rig.panel.last?.targetIsSelection == true)
        let oldClick = try #require(rig.panel.replace)
        oldClick()
        await waitUntil { rig.reader.replaceCount == 1 }
        #expect(rig.reader.replaced?.range == rig.reader.selectionOverride)
        try rig.edit("新文档", element: "second")
        oldClick()
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.reader.replaceCount == 1)
    }

    @Test
    func unsupportedCaptureExplainsItsDisabledActionAndStaleInputStillInvalidatesIt() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        // Text markers can replace an explicit selection, but this caret-only capture cannot
        // select a sentence through that editor API. The composition-capable input source itself
        // is not what makes this capture unsupported.
        rig.reader.usesTextMarkers = true
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        #expect(rig.panel.last?.canReplace == false)
        #expect(rig.panel.last?.replacementUnavailableReason?.contains("read-only") == true)
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: [.maskAlternate, .maskControl])) == .consume)
        await waitUntil { rig.panel.last?.isExpanded == true }
        #expect(rig.reader.replaceCount == 0)
        let old = try #require(rig.panel.replace)
        try rig.edit("我正在输入", marked: .init(location: 2, length: 2))
        old()
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.reader.replaceCount == 0)
        #expect(!rig.panel.isVisible)
    }

    @Test
    func positiveMarkedRangeAfterCapturePreventsAnyConfirmedWrite() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.canReplace == true }
        let oldClick = try #require(rig.panel.replace)

        rig.reader.markedRangeOverride = NSRange(location: 2, length: 2)
        oldClick()
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: [.maskAlternate, .maskControl])) == .consume)
        for _ in 0..<20 { await Task.yield() }

        #expect(rig.reader.replaceCount == 0, "A positive marked range rejects the saved preview before either write path.")
    }

    @Test
    func failedReplacementCannotBeRetriedAndNewDocumentDoesNotInheritOldSpinner() async throws {
        let gate = PauseGate(), rig = try Rig()
        defer { gate.finishAll(); rig.cleanup() }
        rig.reader.replacementGate = gate
        rig.coordinator.start()
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.canReplace == true }
        let click = try #require(rig.panel.replace)
        click(); click()
        await waitUntil { gate.pending.count == 1 }
        #expect(rig.reader.replaceCount == 1)
        try rig.edit("新的句子", element: "other-field")
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        await waitUntil { rig.service.requests.count == 2 }
        rig.service.emit("A new sentence.")
        await waitUntil { rig.panel.last?.translation == "A new sentence." }
        #expect(rig.panel.last?.isCommitting == false)
        gate.release(0)
        await waitUntil { rig.panel.last?.canReplace == true }
        #expect(rig.reader.replaceCount == 1)
        rig.reader.replacementGate = nil
        rig.reader.failReplacement = true
        rig.panel.replace?()
        await waitUntil { rig.panel.last?.message == "uncertain write" }
        #expect(rig.panel.last?.canReplace == false)
        #expect(rig.panel.last?.isExpanded == true, "Failure exposes both recovery copy actions.")
        rig.panel.replace?()
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.reader.replaceCount == 2)
    }

    @Test
    func explicitCaptureFailureShowsAnErrorAndShortcutLabelsRepaintWithoutRegeneration() async throws {
        let rig = try Rig(initial: "   ")
        defer { rig.cleanup() }
        rig.coordinator.start()
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        await waitUntil { rig.panel.last?.isError == true }
        #expect(rig.panel.last?.message.isEmpty == false)
        #expect(rig.panel.last?.canReplace == false)
        try rig.edit("我能做到")
        await waitUntil { rig.service.requests.count == 1 }
        rig.service.emit("I can do it.")
        await waitUntil { rig.panel.last?.translation.isEmpty == false }
        rig.settings.languageLearning.keyLabel = "⌥R"
        rig.settings.languageLearning.replacementKeyLabel = "⌃⌥R"
        await waitUntil { rig.panel.last?.shortcutLabel == "⌥R" && rig.panel.last?.replacementShortcutLabel == "⌃⌥R" }
        #expect(rig.service.requests.count == 1)
    }

    /// Hold debounce completion explicitly so assertions never depend on machine speed. Obsolete
    /// waits may resume too; the production request identity must still reject their publication.
    @MainActor
    private final class PauseGate {
        var pending: [CheckedContinuation<Void, Never>?] = []
        var durations: [Duration] = []
        func wait(_ duration: Duration) async {
            durations.append(duration)
            await withCheckedContinuation { pending.append($0) }
        }
        func release(_ index: Int) {
            pending[index]?.resume()
            pending[index] = nil
        }
        func finishAll() { for index in pending.indices { release(index) } }
    }

    @MainActor
    private final class Rig {
        let suite = "io.ichthyoplanktonzyh.lingrove.tests.SentencePreview-\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: SuggestionSettingsModel
        let service: StreamService
        let focus: RigFocusProvider
        let reader: SentenceReader
        let panel = SentencePanel()
        let coordinator: LearningSentencePreviewCoordinator
        let pause: PauseGate?

        init(
            initial: String = "", selection: NSRange? = nil, isFrontmost: @escaping @MainActor () -> Bool = { true },
            availability: @escaping @MainActor () -> String? = { nil }, pause: PauseGate? = nil,
            unitRecognizer: (any LearningUnitRecognizing)? = nil) throws {
            self.pause = pause
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
            settings.languageLearning.translationEnabled = true
            settings.languageLearning.sentencePreviewEnabled = true
            settings.languageLearning.model = "learning-model"
            service = StreamService(settings: settings)
            let value = initial as NSString
            let context = LingroveTestFixtures.focusedInputSnapshot(
                precedingText: selection.map { value.substring(to: $0.location) } ?? initial,
                trailingText: selection.map { value.substring(from: NSMaxRange($0)) } ?? "",
                selection: selection, documentLength: initial.utf16.count)
            focus = RigFocusProvider(snapshot: FocusSnapshot(applicationName: context.applicationName,
                bundleIdentifier: context.bundleIdentifier, capability: .supported, context: context))
            reader = SentenceReader(focus: focus)
            if let selection { reader.valueOverride = initial; reader.selectionOverride = selection }
            coordinator = LearningSentencePreviewCoordinator(service: service, reader: reader, focus: focus,
                panel: panel, unitRecognizer: unitRecognizer, debounce: pause == nil ? .zero : .milliseconds(600),
                waitForPause: { delay in
                    if let pause { await pause.wait(delay) } else { try await Task.sleep(for: delay) }
                }, isFrontmost: { _ in isFrontmost() },
                frontmostBundle: { [focus] in focus.snapshot.bundleIdentifier }, availability: availability)
        }

        func edit(_ text: String, element: String = "field", marked: NSRange? = nil,
                  capability: FocusCapability = .supported,
                  caret: CGRect = CGRect(x: 10, y: 20, width: 2, height: 18), publishesBeforeStorage: Bool = false) throws {
            let old = focus.snapshot.context
            let sequence = (old?.focusChangeSequence ?? 1) + (old?.elementIdentifier == element ? 0 : 1)
            let context = LingroveTestFixtures.focusedInputSnapshot(elementIdentifier: element, caretRect: caret, precedingText: text,
                focusChangeSequence: sequence, hostMarkedTextRange: marked, documentLength: text.utf16.count)
            let snapshot = FocusSnapshot(applicationName: context.applicationName, bundleIdentifier: context.bundleIdentifier,
                capability: capability, context: context)
            if publishesBeforeStorage { focus.snapshotSubject.send(snapshot) }
            focus.snapshot = snapshot
            if !publishesBeforeStorage { focus.snapshotSubject.send(snapshot) }
        }

        func cleanup() {
            coordinator.stop()
            pause?.finishAll()
            service.cleanup()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// Controllable translation transport; stale callbacks remain callable to exercise latest-wins guards.
    private final class StreamService: LearningSentenceGenerating {
        // A transport-owned row records the source of one controllable request.
        // swiftlint:disable:next nesting
        struct Request { let source: String }
        let settings: SuggestionSettingsModel
        var requests: [Request] = []
        var inputs: [LearningTranslationInput] = []
        var pending: [UUID: CheckedContinuation<String, Error>] = [:]
        var translationIDs: [Int: UUID] = [:]
        var cancelledTranslation = 0
        var translationCallbacks: [(String) -> Void] = []
        init(settings: SuggestionSettingsModel) { self.settings = settings }
        private func wait(index: Int) async throws -> String {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation {
                    pending[id] = $0
                    translationIDs[index] = id
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
                    self.cancelledTranslation += 1
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
        func translateSentence(input: LearningTranslationInput, sourceLanguage: LearningLanguage?,
                               targetLanguage: LearningLanguage, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
            translationCallbacks.append(onPartial)
            return try await translateSentence(input: input, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        }
        func translateSentence(input: LearningTranslationInput, sourceLanguage: LearningLanguage?,
                               targetLanguage: LearningLanguage) async throws -> String {
            inputs.append(input)
            return try await translateSentence(source: input.source, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        }
        func translateSentence(source: String, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage) async throws -> String {
            let index = requests.count
            requests.append(.init(source: source))
            return try await wait(index: index)
        }
        func emit(_ text: String, request: Int? = nil) {
            let index = request ?? (requests.count - 1)
            guard requests.indices.contains(index) else { Issue.record("No generation request to deliver to"); return }
            if let id = translationIDs[index] { pending.removeValue(forKey: id)?.resume(returning: text) }
        }
        func failTranslation() {
            if let id = translationIDs[requests.count - 1] {
                pending.removeValue(forKey: id)?.resume(throwing: LearningFailure.message("translation unavailable"))
            }
        }
        func cleanup() { for continuation in pending.values { continuation.resume(throwing: CancellationError()) }; pending.removeAll() }
    }

    private final class SentenceReader: LearningSelectionReplacing {
        let focus: RigFocusProvider
        var replaceCount = 0
        var isComposingInputMethod = true
        var markedRangeOverride: NSRange?
        var usesTextMarkers = false
        var selectionOverride: NSRange?
        var valueOverride: String?
        var replacementGate: PauseGate?
        var failReplacement = false
        var replaced: LearningSelectionCapture?
        var replacementText: String?
        init(focus: RigFocusProvider) { self.focus = focus }
        func capture() throws -> LearningSelectionCapture {
            let context = try #require(focus.snapshot.context)
            let value = valueOverride ?? context.precedingText
            let range = try LearningTextScopePolicy.conversionRange(value: value, selection: selectionOverride ?? context.documentSelection)
            let inputMethodAssessment = LearningInputMethodPolicy.assess(
                markedRange: markedRangeOverride,
                isComposingInputMethod: isComposingInputMethod
            )
            if let reason = inputMethodAssessment.previewRejectionReason {
                throw LearningFailure.message(reason)
            }
            return .init(
                element: AXUIElementCreateApplication(123), context: context, value: value,
                range: range, source: try LearningTextScopePolicy.text(value: value, range: range),
                usesTextMarkers: usesTextMarkers,
                editorSelection: selectionOverride ?? context.documentSelection,
                replacementUnavailableReason: inputMethodAssessment.replacementUnavailableReason,
                inputMethodAssessment: inputMethodAssessment)
        }
        func isCurrent(_ saved: LearningSelectionCapture) -> Bool {
            guard let current = try? capture() else { return false }
            return current.context == saved.context && current.value.utf16.elementsEqual(saved.value.utf16) &&
                current.range == saved.range && current.originalSelection == saved.originalSelection &&
                current.hasSameReplacementSafety(as: saved)
        }
        func replace(_ saved: LearningSelectionCapture, with english: String) async throws {
            replaceCount += 1; replaced = saved; replacementText = english
            if let replacementGate { await replacementGate.wait(.zero) }
            try Task.checkCancellation()
            if failReplacement { throw LearningFailure.message("uncertain write") }
        }
    }

    private final class SentencePanel: LearningSentencePresenting {
        var isVisible = false
        var hasDetail = false
        var last: LearningSentencePresentation?
        var showCount = 0
        var replace: (() -> Void)?
        func hide() { isVisible = false }
        func dismissDetail() -> Bool {
            guard hasDetail else { return false }
            hasDetail = false
            return true
        }
        func show(
            _ presentation: LearningSentencePresentation, expand: @escaping () -> Void, dismiss: @escaping () -> Void,
            replace: (() -> Void)?
        ) {
            self.replace = replace
            show(presentation, expand: expand, dismiss: dismiss)
        }
        func show(_ presentation: LearningSentencePresentation, expand: @escaping () -> Void, dismiss: @escaping () -> Void) {
            showCount += 1
            isVisible = true
            last = presentation
        }
    }
}

private actor UnitGate: LearningUnitRecognizing {
    var pending: [String: CheckedContinuation<[LearningUnit], Never>] = [:]
    var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    func recognize(_ translation: String, language: LearningLanguage) async throws -> [LearningUnit] {
        await withCheckedContinuation {
            pending[translation] = $0
            waiters.removeValue(forKey: translation)?.resume()
        }
    }
    func waitFor(_ text: String) async {
        if pending[text] != nil { return }
        await withCheckedContinuation { waiters[text] = $0 }
    }
    func finish(_ text: String, units: [LearningUnit]) { pending.removeValue(forKey: text)?.resume(returning: units) }
}
