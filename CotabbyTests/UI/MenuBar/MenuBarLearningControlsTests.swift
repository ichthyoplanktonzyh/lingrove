import AppKit
import SwiftUI
import Testing
@testable import Cotabby

/// Production controls render with private defaults and a silent speaker. The opt-in window
/// supports external native AX acceptance; no system permissions, real notebook data or
/// inference requests are needed. Unit checks cover bounded layout and lazy catalog access.
@MainActor
@Suite(.serialized)
struct MenuBarLearningControlsTests {
    private static var retained: [AnyObject] = []

    @Test func learningMenuBoundsLongContentAndDoesNotEnumerateVoices() async throws {
        let suite = "MenuControls-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LanguageLearningSettings(defaults: defaults)
        settings.translationEnabled = true; settings.screenshotTranslationEnabled = true
        let provider = MenuSilentSpeaker()
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults), provider: provider)
        let host = NSHostingView(rootView: MenuBarContentViewport(maximumHeight: 300) {
            MenuBarLearningControls(settings: settings, speech: speech, screenRecordingGranted: false, open: { _ in }, review: {})
        }.padding(16).frame(width: 340))
        let window = makeWindow(host)
        defer { speech.stop(); window.close() }
        Self.retained.append(settings)
        Self.retained.append(speech)
        await settle(host)
        #expect(host.fittingSize.height >= 300 && host.fittingSize.height <= 333)
        #expect(provider.refreshes == 0 && speech.phase == nil)
        // Changes from the main Settings window repaint the existing menu without catalog work.
        settings.translation.backend = .local
        settings.translation.localModel = String(repeating: "long-model-name-", count: 20) + ".gguf"
        settings.readingTargetLanguage = .japanese
        speech.settings.setRateMultiplier(1.4)
        await settle(host)
        #expect(host.fittingSize.width == 340 && host.fittingSize.height <= 333)
        #expect(provider.refreshes == 0 && speech.phase == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COTABBY_UI_MENU_REVIEW"] == "1"))
    func nativeMenuCanBeReviewedWithIsolatedPreferences() async throws {
        let suite = "MenuControls-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("learning", forKey: "menuBarTask")
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        settings.languageLearning.translationEnabled = true
        settings.languageLearning.selectionTranslationEnabled = true
        settings.languageLearning.pointerTranslationEnabled = true
        settings.languageLearning.screenshotTranslationEnabled = true
        let provider = MenuSilentSpeaker()
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults), provider: provider)
        let permission = PermissionManager()
        let runtime = RuntimeBootstrapModel(runtimeManager: LlamaRuntimeManager(), userDefaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MenuModels-" + UUID().uuidString)
        let downloads = ModelDownloadManager(runtimeDirectoryURL: directory, assetCatalog: [])
        let host = NSHostingView(rootView: MenuBarView(permissionManager: permission, runtimeModel: runtime,
            modelDownloadManager: downloads, focusModel: FocusTrackingModel(permissionProvider: { false }, ignoredBundleIdentifier: nil),
            permissionGuidanceController: PermissionGuidanceController(permissionManager: permission), suggestionSettings: settings,
            foundationModelAvailabilityService: FoundationModelAvailabilityService(), powerSourceMonitor: PowerSourceMonitor(),
            speech: speech, appUpdateManager: AppUpdateManager(), onOpenSettings: {}, onReportFeedback: {})
            .defaultAppStorage(defaults))
        let window = makeWindow(host)
        window.title = "Lingrove menu acceptance"
        window.level = .floating
        defer { speech.stop(); settings.clearPause(); window.close() }
        Self.retained.append(settings)
        Self.retained.append(speech)
        Self.retained.append(runtime)
        await settle(host)
        speech.toggle(.init(target: .init(ownerID: UUID(), itemID: "menu.acceptance"),
            text: "A silent acceptance fixture.", language: .english))
        #expect(host.fittingSize.width == 340)
        let duration = Int(ProcessInfo.processInfo.environment["COTABBY_UI_REVIEW_SECONDS"] ?? "120") ?? 120
        try await Task.sleep(for: .seconds(min(240, max(1, duration))))
        #expect(speech.phase == nil && provider.stops == 1)
    }

    private func makeWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 120, y: 100, width: 340, height: 720),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(40)); view.layoutSubtreeIfNeeded() }
    }

}

@MainActor
private final class MenuSilentSpeaker: SpeechProviding {
    var eventHandler: (@MainActor @Sendable (SpeechProviderEvent) -> Void)?
    var refreshes = 0
    var stops = 0
    func refreshVoices() throws -> [SpeechVoice] {
        refreshes += 1
        return [.init(id: "fixture", name: "Fixture", language: "en-US", quality: .standard)]
    }
    func speak(_ text: String, voice: SpeechVoice, rateMultiplier: Double, token: SpeechPlaybackToken) throws {
        eventHandler?(.started(token))
    }
    func stop(token: SpeechPlaybackToken) { stops += 1 }
}
