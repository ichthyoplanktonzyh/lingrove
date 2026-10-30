import AppKit
import SwiftUI

/// File overview:
/// Owns Lingrove's settings window as a long-lived AppKit resource.
/// This lives in `App/` for the same reason as `WelcomeCoordinator`: window lifetime and activation
/// rules are application concerns, while SwiftUI only renders the content hosted inside the window.
///
/// In frontend terms, this is closer to a route/window controller than a pure view. The important
/// invariant is that the app only creates one settings window and reuses it when the user opens
/// Settings again from the menu.
@MainActor
final class SettingsCoordinator: NSObject, NSWindowDelegate {
    private let cli: CLIInstallationModel?
    private let learningModels: LearningModelCollection?
    /// Borrow the app-owned speaker so settings previews share playback with the learning cards.
    /// Reopening this window must never create a second synthesizer or a separate voice preference.
    private let speech: LearningSpeechController?
    private let review: AnkiReviewController?
    private let vocabularySearch: VocabularySearchController?
    private let appUpdateManager: AppUpdateManager
    private let permissionManager: PermissionManager
    private let permissionGuidanceController: PermissionGuidanceController
    private let suggestionSettings: SuggestionSettingsModel
    private let attentionModel: SettingsAttentionModel
    private let interfaceLanguageSettings: InterfaceLanguageSettingsModel
    private let openAICompatibleConnectionModel: OpenAICompatibleConnectionModel
    private let foundationModelAvailabilityService: FoundationModelAvailabilityService
    private let runtimeModel: RuntimeBootstrapModel
    private let modelDownloadManager: ModelDownloadManager
    private let huggingFaceSearchService: HuggingFaceSearchService
    private let performanceMetricsStore: PerformanceMetricsStore
    private let qualityMetricsStore: SuggestionQualityMetricsStore
    private let systemMetricsStore: SystemMetricsStore
    private let onShowWelcome: () -> Void
    private let clearEmojiHistory: () -> Void
    private let typingHistoryStore: TypingHistoryStore
    private let applicationRelauncher = ApplicationRelauncher()

    private var settingsWindowController: NSWindowController?
    private let navigation = SettingsNavigationModel()

    func showLearningModel(_ role: LearningModelRole) {
        navigation.openLearningModel(role)
        showSettings()
    }

    func showReviewSettings() {
        navigation.openLearningTask(.review)
        showSettings()
    }

    func showVocabularySearchModels() {
        navigation.openEngineTask(.vocabularySearch)
        showSettings()
    }

    func showSettings(at destination: MenuBarSettingsDestination) {
        navigation.openMenuDestination(destination)
        showSettings()
    }

    /// Setup links use the same exact-row router as search and help, preserving one settings owner.
    func showSettings(revealing item: SettingsItem) {
        navigation.showsUsageGuide = false
        navigation.reveal(item)
        showSettings()
    }

    func showUsageGuide() {
        navigation.showsUsageGuide = true
        showSettings()
    }

    init(
        cli: CLIInstallationModel? = nil,
        learningModels: LearningModelCollection? = nil,
        speech: LearningSpeechController? = nil,
        review: AnkiReviewController? = nil,
        vocabularySearch: VocabularySearchController? = nil,
        appUpdateManager: AppUpdateManager,
        permissionManager: PermissionManager,
        permissionGuidanceController: PermissionGuidanceController,
        suggestionSettings: SuggestionSettingsModel,
        interfaceLanguageSettings: InterfaceLanguageSettingsModel,
        openAICompatibleConnectionModel: OpenAICompatibleConnectionModel,
        foundationModelAvailabilityService: FoundationModelAvailabilityService,
        runtimeModel: RuntimeBootstrapModel,
        modelDownloadManager: ModelDownloadManager,
        huggingFaceSearchService: HuggingFaceSearchService,
        performanceMetricsStore: PerformanceMetricsStore,
        qualityMetricsStore: SuggestionQualityMetricsStore,
        systemMetricsStore: SystemMetricsStore,
        onShowWelcome: @escaping () -> Void,
        clearEmojiHistory: @escaping () -> Void,
        typingHistoryStore: TypingHistoryStore
    ) {
        self.cli = cli
        self.learningModels = learningModels
        self.speech = speech
        self.review = review
        self.vocabularySearch = vocabularySearch
        self.appUpdateManager = appUpdateManager
        self.permissionManager = permissionManager
        self.permissionGuidanceController = permissionGuidanceController
        self.suggestionSettings = suggestionSettings
        self.attentionModel = SettingsAttentionModel(
            permissionManager: permissionManager, suggestionSettings: suggestionSettings,
            foundationAvailability: foundationModelAvailabilityService,
            runtimeModel: runtimeModel, connectionModel: openAICompatibleConnectionModel)
        self.interfaceLanguageSettings = interfaceLanguageSettings
        self.openAICompatibleConnectionModel = openAICompatibleConnectionModel
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.huggingFaceSearchService = huggingFaceSearchService
        self.performanceMetricsStore = performanceMetricsStore
        self.qualityMetricsStore = qualityMetricsStore
        self.systemMetricsStore = systemMetricsStore
        self.onShowWelcome = onShowWelcome
        self.clearEmojiHistory = clearEmojiHistory
        self.typingHistoryStore = typingHistoryStore
    }

    /// Shows the settings window, reusing and restoring the existing instance when possible.
    /// Reusing one window avoids subtle state duplication and matches standard macOS settings
    /// behavior where there is a single shared preferences surface for the app.
    func showSettings() {
        if let window = settingsWindowController?.window {
            // The app delegate handles reopen events itself, so AppKit will not restore a
            // miniaturized Settings window as part of its default reopen behavior.
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: AnyView(
                SettingsContainerView(
                    cli: cli,
                    learningModels: learningModels,
                    speech: speech,
                    review: review,
                    vocabularySearch: vocabularySearch,
                    attentionModel: attentionModel,
                    appUpdateManager: appUpdateManager,
                    permissionManager: permissionManager,
                    permissionGuidanceController: permissionGuidanceController,
                    suggestionSettings: suggestionSettings,
                    interfaceLanguageSettings: interfaceLanguageSettings,
                    openAICompatibleConnectionModel: openAICompatibleConnectionModel,
                    foundationModelAvailabilityService: foundationModelAvailabilityService,
                    runtimeModel: runtimeModel,
                    modelDownloadManager: modelDownloadManager,
                    huggingFaceSearchService: huggingFaceSearchService,
                    performanceMetricsStore: performanceMetricsStore,
                    qualityMetricsStore: qualityMetricsStore,
                    systemMetricsStore: systemMetricsStore,
                    onShowWelcome: onShowWelcome,
                    onRestart: { [applicationRelauncher] in try applicationRelauncher.restart() },
                    clearEmojiHistory: clearEmojiHistory,
                    typingHistoryStore: typingHistoryStore,
                    onQuit: { NSApplication.shared.terminate(nil) }, navigation: navigation
                )
            )
        )
        // Sized so the native split view opens with a readable sidebar, a comfortable grouped
        // detail form, and room for the Home pane's status-card row to breathe. The user can still
        // resize from here; the sidebar provides its own range.
        let initialFrame = CGRect(x: 0, y: 0, width: 1060, height: 720)
        let minSize = NSSize(width: 900, height: 560)
        // Bump the autosave name to reset everyone onto the current default instead of restoring
        // any narrower frame saved before the Home redesign.
        let autosaveName = "LingroveSettingsWindowV7"

        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Settings")
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = minSize
        window.setFrameAutosaveName(autosaveName)
        window.delegate = self
        window.contentViewController = hostingController

        let windowController = NSWindowController(window: window)
        settingsWindowController = windowController

        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }

        if closingWindow == settingsWindowController?.window {
            settingsWindowController = nil
        }
    }
}
