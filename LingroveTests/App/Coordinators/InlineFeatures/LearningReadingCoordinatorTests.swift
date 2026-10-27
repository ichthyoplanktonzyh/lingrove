import AppKit
import Combine
import Foundation
import Testing

@testable import Lingrove

/// These tests exercise the real tap decisions and latest-wins lifecycle with immutable receipts.
/// They never query Accessibility, synthesize keys, write clipboard content or load a model.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LearningReadingCoordinatorTests {
    @Test func immediateRepeatedShortcutJoinsThePendingMouseUpCapture() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(.selection)
        rig.settings.languageLearning.selectionIconEnabled = false
        rig.reader.blockEnrichment = true
        await settle()
        let start = CGPoint(x: 500, y: 500), end = CGPoint(x: 400, y: 500)
        rig.coordinator.handlePointerEvent(type: .leftMouseDown, at: start, clickCount: 1)
        rig.coordinator.handlePointerEvent(type: .leftMouseUp, at: end, clickCount: 1)
        let checks = rig.reader.currentChecks
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        #expect(rig.reader.currentChecks == checks && rig.reader.calls == 0)
        for _ in 0..<100 where rig.reader.pendingEnrichment == nil { try await Task.sleep(for: .milliseconds(5)) }
        let capture = try #require(rig.reader.enrichmentCapture)
        #expect(capture.gesture?.selectionID == capture.id && capture.gesture?.start == start && capture.gesture?.end == end)
        #expect(rig.reader.calls == 1 && rig.reader.enrichCalls == 1 && rig.service.calls.isEmpty)
        rig.reader.finishEnrichment()
        await until { rig.service.calls.count == 1 }
    }

    @Test(arguments: [false, true])
    func shortcutReusesTheGestureReceiptEvenWhenTheIconIsDisabled(_ backward: Bool) async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(.selection)
        rig.settings.languageLearning.selectionIconEnabled = false
        rig.reader.blockEnrichment = true
        await settle()
        let left = CGPoint(x: 400, y: 500), right = CGPoint(x: 500, y: 500)
        rig.coordinator.handlePointerEvent(type: .leftMouseDown, at: backward ? right : left, clickCount: 1)
        rig.coordinator.handlePointerEvent(type: .leftMouseUp, at: backward ? left : right, clickCount: 1)
        for _ in 0..<100 where rig.reader.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.reader.calls == 1 && rig.icon.action == nil && rig.service.calls.isEmpty)
        let checks = rig.reader.currentChecks
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        #expect(rig.reader.currentChecks == checks, "The consuming shortcut callback must not perform AX checks")
        await until { rig.reader.pendingEnrichment != nil }
        let capture = try #require(rig.reader.enrichmentCapture)
        let gesture = try #require(capture.gesture)
        #expect(gesture.selectionID == capture.id && gesture.start == (backward ? right : left))
        #expect(gesture.end == (backward ? left : right) && rig.reader.calls == 1)
        rig.reader.finishEnrichment()
        await until { rig.service.calls.count == 1 }
    }

    @Test func scrollingRetiresTheHiddenGestureBeforeAShortcutCanReuseIt() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(.selection)
        rig.settings.languageLearning.selectionIconEnabled = false
        rig.reader.blockEnrichment = true
        await settle()
        rig.coordinator.handlePointerEvent(type: .leftMouseDown, at: CGPoint(x: 400, y: 500), clickCount: 1)
        rig.coordinator.handlePointerEvent(type: .leftMouseUp, at: CGPoint(x: 500, y: 500), clickCount: 1)
        for _ in 0..<100 where rig.reader.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        rig.coordinator.handlePointerEvent(type: .scrollWheel, at: CGPoint(x: 500, y: 500), clickCount: 0)
        #expect(!rig.coordinator.isActive)
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.reader.pendingEnrichment != nil }
        #expect(rig.reader.calls == 2 && rig.reader.enrichmentCapture?.gesture == nil)
    }

    @Test func passiveIconAppearsBeforeOCRAndClickStartsOnlyOneRequest() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(.selection)
        rig.settings.languageLearning.selectionIconEnabled = true
        rig.reader.blockEnrichment = true
        await settle()
        rig.coordinator.handlePointerEvent(type: .leftMouseUp, at: CGPoint(x: 500, y: 500), clickCount: 2)
        for _ in 0..<100 where rig.icon.action == nil { try await Task.sleep(for: .milliseconds(5)) }
        let click = try #require(rig.icon.action)
        #expect(rig.reader.enrichCalls == 0 && rig.service.calls.isEmpty)
        click(); click()
        await until { rig.reader.pendingEnrichment != nil }
        #expect(rig.reader.enrichCalls == 1 && rig.service.calls.isEmpty)
        #expect(rig.icon.preparing)
        rig.reader.finishEnrichment()
        await until { rig.service.calls.count == 1 }
        #expect(rig.service.calls.count == 1 && rig.reader.enrichCalls == 1)
    }

    @Test func changingSelectionDuringOCRRetiresItBeforeAnyModelRequest() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(.selection)
        rig.reader.blockEnrichment = true
        await settle()
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.reader.pendingEnrichment != nil }
        rig.reader.current = false
        rig.reader.invalidation?()
        await settle()
        #expect(rig.reader.pendingEnrichment == nil && rig.service.calls.isEmpty && !rig.coordinator.isActive)
    }
    @Test func hostScrollCancelsPointerOCRBeforeAnyModelRequest() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(.pointer)
        rig.reader.blockCapture = true
        await settle()
        #expect(rig.coordinator.decide(rig.shortcut(for: .pointer)) == .consume)
        await until { rig.reader.pendingCapture != nil }
        let forgets = rig.reader.forgets
        rig.coordinator.handlePointerEvent(type: .scrollWheel, at: CGPoint(x: 500, y: 500), clickCount: 0)
        await settle()
        #expect(rig.reader.pendingCapture == nil && rig.reader.forgets > forgets)
        #expect(rig.service.calls.isEmpty && !rig.panel.isVisible)
    }

    @Test
    func nativeLookupGestureDoesNotDismissOrCreateANewSelectionRequest() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(.selection)
        rig.settings.languageLearning.selectionIconEnabled = true
        await settle()
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.service.calls.count == 1 }
        rig.service.finish(0, "译文")
        await until { rig.panel.isVisible }
        let captures = rig.reader.calls
        rig.panel.containsInteraction = true
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .scrollWheel] {
            rig.coordinator.handlePointerEvent(type: type, at: CGPoint(x: 200, y: 200), clickCount: 0)
            #expect(rig.panel.isVisible && rig.coordinator.isActive)
        }
        // A dictionary drag released outside still belongs to the lookup, even when AppKit
        // reports a double click. It must not schedule the passive selection affordance.
        rig.panel.containsInteraction = false
        rig.coordinator.handlePointerEvent(type: .leftMouseUp, at: CGPoint(x: 500, y: 500), clickCount: 2)
        try await Task.sleep(for: .milliseconds(220))
        #expect(rig.panel.isVisible && rig.reader.calls == captures)
        rig.coordinator.handlePointerEvent(type: .leftMouseDown, at: CGPoint(x: 500, y: 500), clickCount: 1)
        #expect(!rig.panel.isVisible && !rig.coordinator.isActive)
    }

    @Test(arguments: LearningReadingSource.allCases)
    func readingStreamsPrefixesAndRevalidatesOnlyCompletedText(_ source: LearningReadingSource) async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(source)
        await settle()
        #expect(rig.coordinator.decide(rig.shortcut(for: source)) == .consume)
        await until { rig.service.calls.count == 1 }
        #expect(!rig.panel.isVisible)
        rig.service.partials[0]("部分")
        #expect(rig.panel.isVisible && rig.panel.last?.translation == "部分")
        #expect(rig.panel.last?.isTranslating == true && rig.panel.last?.canReplace == false)
        let checks = rig.reader.currentChecks
        rig.service.partials[0]("部分译文")
        #expect(rig.reader.currentChecks == checks, "Intermediate display must not repeatedly traverse AX")
        rig.service.finish(0, "完整译文")
        await until { rig.panel.last?.isTranslating == false }
        #expect(rig.panel.last?.isTranslating == false && rig.panel.last?.translation == "完整译文")
        #expect(rig.reader.currentChecks > checks, "Completion still revalidates the original receipt")
        rig.coordinator.dismiss()
        rig.service.partials[0]("旧结果")
        #expect(!rig.panel.isVisible)
    }

    @Test(arguments: LearningReadingSource.allCases)
    func failedReadingStreamClearsThePrefixAndRejectsLateUpdates(_ source: LearningReadingSource) async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(source)
        await settle()
        #expect(rig.coordinator.decide(rig.shortcut(for: source)) == .consume)
        await until { rig.service.calls.count == 1 }
        rig.service.partials[0]("部分")
        rig.service.pending.removeValue(forKey: 0)?.resume(throwing: LearningFailure.message("stream failed"))
        await until { rig.panel.last?.isError == true }
        #expect(rig.panel.last?.translation.isEmpty == true && rig.panel.last?.isTranslating == false)
        rig.service.partials[0]("迟到的部分")
        #expect(rig.panel.last?.translation.isEmpty == true && rig.panel.last?.isError == true)
    }

    @Test(arguments: LearningReadingSource.allCases)
    func sourceIdentityReachesTranslationWhenOtherEntrypointsAreOff(_ source: LearningReadingSource) async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(source)
        await settle()
        #expect(rig.coordinator.decide(rig.shortcut(for: source)) == .consume)
        await until { rig.service.calls.count == 1 }
        #expect(rig.service.calls.first?.readingSource == source)
        rig.service.finish(0, "译文")
        await until { rig.panel.last?.isTranslating == false }
        #expect(rig.panel.last?.translation == "译文")
        for other in LearningReadingSource.allCases where other != source {
            rig.setSource(other, enabled: true)
            rig.setSource(other, enabled: false)
        }
        await settle()
        #expect(rig.panel.isVisible && rig.panel.last?.translation == "译文")
    }

    @Test(arguments: LearningReadingSource.allCases)
    func unrelatedEntryChangesKeepWorkAndCardButOwnEntryRetiresBoth(_ source: LearningReadingSource) async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(source)
        await settle()
        #expect(rig.coordinator.decide(rig.shortcut(for: source)) == .consume)
        await until { rig.service.calls.count == 1 }
        for other in LearningReadingSource.allCases where other != source { rig.setSource(other, enabled: true) }
        await settle()
        #expect(!rig.panel.isVisible && rig.coordinator.isActive)
        rig.service.finish(0, "仍然有效")
        await until { rig.panel.last?.translation == "仍然有效" }
        for other in LearningReadingSource.allCases where other != source { rig.setSource(other, enabled: false) }
        await settle()
        #expect(rig.panel.isVisible && rig.panel.last?.translation == "仍然有效")
        #expect(rig.coordinator.decide(rig.shortcut(for: source)) == .consume)
        await until { rig.service.calls.count == 2 }
        rig.setSource(source, enabled: false)
        #expect(!rig.panel.isVisible && !rig.coordinator.isActive)
        rig.service.finish(1, "旧结果")
        await settle()
        #expect(!rig.panel.isVisible)
        #expect(rig.coordinator.decide(rig.shortcut(for: source)) == .notHandled)
    }

    @Test func aRetiredRequestsSourceCannotInvalidateTheReadersNextReceipt() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.enableOnly(.pointer)
        await settle()
        #expect(rig.coordinator.decide(rig.shortcut(for: .pointer)) == .consume)
        await until { rig.service.calls.count == 1 }
        rig.coordinator.dismiss()
        let forgets = rig.reader.forgets
        rig.setSource(.pointer, enabled: false)
        await settle()
        #expect(rig.reader.forgets == forgets)
        rig.service.finish(0, "旧结果")
        await settle()
        #expect(!rig.panel.isVisible)
    }

    @Test(arguments: [LearningReadingSource.pointer, .screenshot])
    func newSourcesRequireTheirOwnSwitchAndAppPermission(_ source: LearningReadingSource) async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        let binding = rig.settings.languageLearning.readingBinding(source)
        let event = InputMonitorKeyEvent(
            keyCode: binding.key, flags: source == .pointer ? [.maskControl, .maskShift] : [.maskControl, .maskAlternate, .maskShift])
        #expect(rig.coordinator.decide(event) == .notHandled)
        if source == .pointer {
            rig.settings.languageLearning.pointerTranslationEnabled = true
        } else {
            rig.settings.languageLearning.screenshotTranslationEnabled = true
        }
        await settle()
        #expect(rig.coordinator.decide(event) == .notHandled)
        rig.settings.updatePerAppTranslationPolicy(bundleIdentifier: "test.allowed", displayName: "Allowed") {
            if source == .pointer { $0.pointerTranslationAllowed = true } else { $0.screenshotTranslationAllowed = true }
        }
        await settle()
        #expect(rig.coordinator.decide(event) == .consume)
        await until { rig.service.calls.count == 1 }
        #expect(rig.reader.lastSource == source)
        rig.service.finish(0, "来自新入口的译文")
        await until { rig.panel.last?.translation.isEmpty == false }
        #expect(rig.panel.last?.canReplace == false && rig.panel.replacement == nil)
        #expect(rig.coordinator.decide(.init(keyCode: 53, flags: [])) == .consume)
        #expect(!rig.panel.isVisible)
    }

    @Test func newSourceConflictChecksBothDirectionsAndResetDisablesNewEntrypoints() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        rig.settings.languageLearning.pointerTranslationEnabled = true
        rig.settings.languageLearning.pointerModifiers = [.option, .shift]
        #expect(rig.settings.readingShortcutConflict(.pointer) != nil)
        #expect(rig.settings.selectionShortcutConflict() != nil)
        rig.settings.languageLearning.resetToDefaults()
        #expect(!rig.settings.languageLearning.pointerTranslationEnabled)
        #expect(!rig.settings.languageLearning.screenshotTranslationEnabled)
        #expect(rig.settings.languageLearning.pointerKeyLabel == "⌃⇧T")
    }

    @Test func screenshotAndPointerCanUseTheirOwnAvailabilityWithoutAXSelection() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        rig.axAvailable = false
        #expect(rig.coordinator.decide(rig.shortcut) == .notHandled)
        rig.settings.languageLearning.screenshotTranslationEnabled = true
        rig.settings.updatePerAppTranslationPolicy(bundleIdentifier: "test.allowed", displayName: "Allowed") {
            $0.screenshotTranslationAllowed = true
        }
        await settle()
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: [.maskControl, .maskAlternate, .maskShift])) == .consume)
        await until { rig.service.calls.count == 1 }
        rig.coordinator.availabilityChanged()
        rig.service.finish(0, "截图译文")
        await until { rig.panel.last?.translation == "截图译文" }
    }

    @Test func escapeCancelsPendingRegionWithoutAnyTranslation() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.settings.languageLearning.screenshotTranslationEnabled = true
        rig.settings.updatePerAppTranslationPolicy(bundleIdentifier: "test.allowed", displayName: "Allowed") {
            $0.screenshotTranslationAllowed = true
        }
        await settle()
        rig.reader.blockCapture = true
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: [.maskControl, .maskAlternate, .maskShift])) == .consume)
        await until { rig.reader.isSelectingRegion }
        #expect(rig.coordinator.decide(.init(keyCode: 0, flags: [])) == .consume)
        #expect(rig.coordinator.decide(.init(keyCode: 53, flags: [])) == .consume)
        await settle()
        #expect(!rig.reader.isSelectingRegion && !rig.coordinator.isActive)
        #expect(rig.service.calls.isEmpty && !rig.panel.isVisible)
    }

    @Test func unknownAndUnapprovedAppsKeepTheirShortcut() async {
        let rig = Rig()
        defer { rig.cleanup() }
        #expect(rig.coordinator.decide(rig.shortcut) == .notHandled)
        rig.allow("test.allowed")
        rig.frontmost = nil
        #expect(rig.coordinator.decide(rig.shortcut) == .notHandled)
        rig.frontmost = "test.other"
        #expect(rig.coordinator.decide(rig.shortcut) == .notHandled)
        await settle()
        #expect(rig.reader.calls == 0 && rig.service.calls.isEmpty)
    }

    @Test func availabilityAndGlobalDisableStillPassTheReadingChordThrough() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        rig.available = false
        #expect(rig.coordinator.decide(rig.shortcut) == .notHandled)
        rig.available = true
        rig.settings.setGloballyEnabled(false)
        #expect(rig.coordinator.decide(rig.shortcut) == .notHandled)
        await settle()
        #expect(rig.reader.calls == 0 && rig.service.calls.isEmpty)
    }

    @Test func switchingAppBeforeCaptureDoesNotReadTheNewApp() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        rig.frontmost = "test.private"
        await settle()
        #expect(rig.reader.calls == 0 && rig.service.calls.isEmpty)
    }

    @Test func conflictWithEffectiveAppBindingDoesNotConsume() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        rig.settings.setPerAppAcceptKey(
            bundleIdentifier: "test.allowed", displayName: "Allowed", keyCode: 17,
            modifiers: [.option, .shift], label: "test")
        #expect(rig.coordinator.decide(rig.shortcut) == .notHandled)
        await settle()
        #expect(rig.reader.calls == 0)
    }

    @Test func oneChordCanServeSeparateAppsWhenWritingCommandsAreDisabled() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        rig.settings.languageLearning.selectionModifiers = [.option]
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .notHandled)
        rig.settings.updatePerAppTranslationPolicy(bundleIdentifier: "test.allowed", displayName: "Allowed") {
            $0.writingTranslationShortcutsAllowed = false
        }
        #expect(rig.settings.selectionShortcutConflict(bundleIdentifier: "test.allowed") == nil)
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        await until { rig.service.calls.count == 1 }
    }

    @Test func readingUsesIndependentDirectionAndHasNoReplacement() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        rig.settings.languageLearning.sourceLanguages = [.chinese]
        rig.settings.languageLearning.targetLanguage = .english
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.service.calls.count == 1 }
        #expect(rig.service.calls[0].source == .english && rig.service.calls[0].target == .chinese)
        rig.service.finish(0, "请随时告诉我最新进展。")
        await until { rig.panel.last?.translation.isEmpty == false }
        #expect(rig.panel.last?.targetIsSelection == true)
        #expect(rig.panel.last?.canReplace == false && rig.panel.replacement == nil)
        #expect(rig.settings.languageLearning.targetLanguage == .english)
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: .maskAlternate)) == .consume)
        await until { rig.panel.last?.isExpanded == true }
        #expect(rig.coordinator.decide(.init(keyCode: 17, flags: [.maskControl, .maskAlternate])) == .notHandled)
    }

    @Test func lateReplyCannotReopenAfterTypingOrSelectionChange() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.service.calls.count == 1 }
        #expect(rig.coordinator.decide(.init(keyCode: 0, flags: [])) == .notHandled)
        rig.service.finish(0, "旧结果")
        await settle()
        #expect(!rig.panel.isVisible)
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.service.calls.count == 2 }
        rig.reader.current = false
        rig.service.finish(1, "选区已经变化")
        await settle()
        #expect(!rig.panel.isVisible)
    }

    @Test func readingTargetAndPermissionChangesRetireOldWork() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.service.calls.count == 1 }
        rig.settings.languageLearning.readingTargetLanguage = .japanese
        rig.service.finish(0, "旧中文结果")
        await settle()
        #expect(!rig.panel.isVisible)
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.service.calls.count == 2 }
        rig.allow("test.allowed", allowed: false)
        rig.service.finish(1, "旧日文结果")
        await settle()
        #expect(!rig.panel.isVisible)
        #expect(rig.coordinator.decide(rig.shortcut) == .notHandled)
    }

    @Test func iconAndUnrelatedAppEditsDoNotCancelTranslation() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.service.calls.count == 1 }
        rig.settings.languageLearning.selectionIconEnabled = true
        rig.settings.updatePerAppTranslationPolicy(bundleIdentifier: "test.other", displayName: "Other") { $0.selectionIcon = .off }
        await settle()
        rig.service.finish(0, "仍然有效")
        await until { rig.panel.last?.translation == "仍然有效" }
        rig.settings.languageLearning.selectionIconEnabled = false
        await settle()
        #expect(rig.panel.isVisible && rig.panel.last?.translation == "仍然有效")
    }

    @Test func newerRequestWinsEvenWhenOldServiceIgnoresCancellation() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.allow("test.allowed")
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.service.calls.count == 1 }
        #expect(rig.coordinator.decide(rig.shortcut) == .consume)
        await until { rig.service.calls.count == 2 }
        rig.service.finish(1, "最新结果")
        await until { rig.panel.last?.translation == "最新结果" }
        rig.service.finish(0, "旧结果")
        await settle()
        #expect(rig.panel.last?.translation == "最新结果")
    }

    @Test func policyAndSettingsSurvivePersistenceAndOldRecordsDecode() throws {
        let rig = Rig()
        defer { rig.cleanup() }
        let old = Data(#"{"bundleIdentifier":"test.old","displayName":"Old"}"#.utf8)
        let decoded = try JSONDecoder().decode(PerAppShortcutOverride.self, from: old)
        #expect(decoded.selectionTranslationAllowed == nil && decoded.selectionIcon == nil)
        rig.allow("test.allowed")
        rig.settings.updatePerAppTranslationPolicy(bundleIdentifier: "test.allowed", displayName: "Allowed") {
            $0.selectionIcon = .off
            $0.writingTranslationShortcutsAllowed = false
        }
        rig.settings.languageLearning.selectionIconEnabled = true
        #expect(!rig.settings.selectionIconAllowed(in: "test.allowed"))
        #expect(!rig.settings.writingTranslationShortcutsAllowed(in: "test.allowed"))
        let loaded = SuggestionSettingsModel(configuration: .standard, userDefaults: rig.defaults)
        #expect(loaded.selectionTranslationAllowed(in: "test.allowed"))
        #expect(!loaded.selectionIconAllowed(in: "test.allowed"))
        #expect(!loaded.writingTranslationShortcutsAllowed(in: "test.allowed"))
        let rows = AppSettingsList.entries(
            inputCounts: [:], disabledRules: [], overrides: loaded.perAppShortcutOverrides,
            excludedFromHistory: [], displayName: { $0 })
        #expect(rows.first?.hasOverrides == true)
    }

    @Test func oversizedAndEmptyTargetsFailWhole() throws {
        #expect(throws: (any Error).self) { try LearningReadingPolicy.validate(" \n ") }
        #expect(throws: (any Error).self) {
            try LearningReadingPolicy.validate(String(repeating: "a", count: ModelContextBudget.maximumTextBytes + 1))
        }
        try LearningReadingPolicy.validate("keep me posted")
    }

    private func settle() async { for _ in 0..<60 { await Task.yield() } }
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition())
    }

    @MainActor private final class Rig {
        let name = "test.reading.\(UUID())"
        let defaults: UserDefaults
        let settings: SuggestionSettingsModel
        let reader = Reader(), panel = Panel(), icon = Icon()
        let service: Service
        var frontmost: String? = "test.allowed"
        var available = true
        var axAvailable = true
        lazy var coordinator = LearningReadingCoordinator(
            service: service, reader: reader, panel: panel, icon: icon,
            frontmostBundle: { [weak self] in self?.frontmost }, availability: { [weak self] in self?.available == true },
            sourceAvailability: { [weak self] source in source != .selection || self?.axAvailable == true },
            observesSystemEvents: false)
        var shortcut: InputMonitorKeyEvent { .init(keyCode: 17, flags: [.maskAlternate, .maskShift]) }
        func shortcut(for source: LearningReadingSource) -> InputMonitorKeyEvent {
            switch source {
            case .selection: shortcut
            case .pointer: .init(keyCode: 17, flags: [.maskControl, .maskShift])
            case .screenshot: .init(keyCode: 17, flags: [.maskControl, .maskAlternate, .maskShift])
            }
        }
        func setSource(_ source: LearningReadingSource, enabled: Bool) {
            switch source {
            case .selection: settings.languageLearning.selectionTranslationEnabled = enabled
            case .pointer: settings.languageLearning.pointerTranslationEnabled = enabled
            case .screenshot: settings.languageLearning.screenshotTranslationEnabled = enabled
            }
        }
        func enableOnly(_ source: LearningReadingSource) {
            for entry in LearningReadingSource.allCases { setSource(entry, enabled: entry == source) }
            settings.updatePerAppTranslationPolicy(bundleIdentifier: "test.allowed", displayName: "Allowed") {
                $0.selectionTranslationAllowed = true
                $0.pointerTranslationAllowed = true
                $0.screenshotTranslationAllowed = true
            }
        }
        init() {
            defaults = UserDefaults(suiteName: name)!
            settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
            settings.languageLearning.translationEnabled = true
            settings.languageLearning.selectionTranslationEnabled = true
            service = Service(settings: settings)
            coordinator.start()
        }
        func allow(_ bundle: String, allowed: Bool = true) {
            settings.updatePerAppTranslationPolicy(bundleIdentifier: bundle, displayName: bundle) {
                $0.selectionTranslationAllowed = allowed
            }
        }
        func cleanup() {
            coordinator.stop()
            service.cancelAll()
            defaults.removePersistentDomain(forName: name)
        }
    }
    private final class Reader: LearningReadingSelecting {
        var calls = 0, current = true
        var forgets = 0
        var currentChecks = 0
        var lastSource = LearningReadingSource.selection
        var blockCapture = false
        var blockEnrichment = false, enrichCalls = 0
        var invalidation: (() -> Void)?
        var pendingEnrichment: CheckedContinuation<LearningReadingSelection, any Error>?
        var enrichmentCapture: LearningReadingSelection?
        func setInvalidationHandler(_ handler: (@MainActor () -> Void)?) { invalidation = handler }
        func enrich(_ capture: LearningReadingSelection) async throws -> LearningReadingSelection {
            enrichCalls += 1
            guard blockEnrichment else { return capture }
            enrichmentCapture = capture
            return try await withCheckedThrowingContinuation { pendingEnrichment = $0 }
        }
        func finishEnrichment() {
            guard let capture = enrichmentCapture else { return }
            let pending = pendingEnrichment; pendingEnrichment = nil; enrichmentCapture = nil
            pending?.resume(returning: capture)
        }
        var isSelectingRegion: Bool { lastSource == .screenshot && pendingCapture != nil }
        var pendingCapture: CheckedContinuation<LearningReadingSelection, any Error>?
        func capture(source: LearningReadingSource) async throws -> LearningReadingSelection {
            lastSource = source
            if blockCapture {
                return try await withCheckedThrowingContinuation { pendingCapture = $0 }
            }
            var receipt = try await capture()
            receipt.source = source
            return receipt
        }
        func capture() async throws -> LearningReadingSelection {
            calls += 1
            current = true
            return .init(
                id: UUID(), text: "Please keep me posted on the progress.", processIdentifier: 123,
                bundleIdentifier: "test.allowed", anchor: .init(x: 200, y: 200, width: 200, height: 20))
        }
        func isCurrent(_ capture: LearningReadingSelection) -> Bool { currentChecks += 1; return current }
        func forget() {
            forgets += 1
            let continuation = pendingCapture
            pendingCapture = nil
            continuation?.resume(throwing: CancellationError())
            let enrichment = pendingEnrichment
            pendingEnrichment = nil; enrichmentCapture = nil
            enrichment?.resume(throwing: CancellationError())
        }
    }
    private final class Icon: LearningSelectionAffordancePresenting {
        var action: (() -> Void)?
        var preparing = false
        func show(anchor: CGRect, action: @escaping () -> Void) { self.action = action; preparing = false }
        func showProgress(anchor: CGRect) { action = nil; preparing = true }
        func hide() { action = nil; preparing = false }
    }
    private final class Service: LearningSentenceGenerating {
        // A transport-owned row keeps the direction and acquisition source of one request.
        // swiftlint:disable:next nesting
        struct Call {
            let source: LearningLanguage?
            let target: LearningLanguage
            let readingSource: LearningReadingSource
        }
        let settings: SuggestionSettingsModel
        var calls: [Call] = []
        var partials: [(String) -> Void] = []
        var pending: [Int: CheckedContinuation<String, any Error>] = [:]
        init(settings: SuggestionSettingsModel) { self.settings = settings }
        func translateReadingSelection(source: String, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage,
                                       readingSource: LearningReadingSource,
                                       onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
            partials.append(onPartial)
            return try await translateReadingSelection(source: source, sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage, readingSource: readingSource)
        }
        func translateReadingSelection(source: String, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage,
                                       readingSource: LearningReadingSource) async throws
            -> String {
            let index = calls.count
            calls.append(.init(source: sourceLanguage, target: targetLanguage, readingSource: readingSource))
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        }
        func translateSentence(source: String, sourceLanguage: LearningLanguage?, targetLanguage: LearningLanguage) async throws -> String {
            Issue.record("Reading must use the reading service contract")
            throw CancellationError()
        }
        func recordDisplay(source: ModelRequestSource, requestID: String) {}
        func finish(_ index: Int, _ text: String) { pending.removeValue(forKey: index)?.resume(returning: text) }
        func cancelAll() {
            let values = pending.values
            pending.removeAll()
            values.forEach { $0.resume(throwing: CancellationError()) }
        }
    }
    private final class Panel: LearningSentencePresenting {
        var isVisible = false
        var containsInteraction = false
        func containsGlobalInteraction(at point: CGPoint) -> Bool { containsInteraction }
        var last: LearningSentencePresentation?
        var replacement: (() -> Void)?
        func hide() { isVisible = false }
        func show(_ presentation: LearningSentencePresentation, expand: @escaping () -> Void, dismiss: @escaping () -> Void) {
            last = presentation
            isVisible = true
        }
        func show(
            _ presentation: LearningSentencePresentation, expand: @escaping () -> Void, dismiss: @escaping () -> Void,
            replace: (() -> Void)?
        ) {
            replacement = replace
            show(presentation, expand: expand, dismiss: dismiss)
        }
    }
}
