import AppKit
import SwiftUI

/// File overview:
/// Owns the first-run welcome experience. This type persists whether onboarding has already been
/// shown and manages the one compact AppKit window that hosts the SwiftUI welcome wizard.
///
/// We keep this in `App/` instead of `UI/` because it owns lifecycle and persistence, not just
/// rendering. In React terms, this is a tiny controller/store plus a window host.
@MainActor
final class WelcomeCoordinator: NSObject, NSWindowDelegate {
    private enum Layout {
        /// Keep a margin between the onboarding window and the screen edges when a step's preferred
        /// height would otherwise exceed the visible screen. The SwiftUI content scrolls to absorb
        /// the difference, so clamping here only ever shrinks the window, never clips the footer.
        static let screenEdgeMargin: CGFloat = 24
    }

    private let permissionManager: PermissionManager
    private let permissionGuidanceController: PermissionGuidanceController
    private let runtimeModel: RuntimeBootstrapModel
    private let modelDownloadManager: ModelDownloadManager
    private let suggestionSettings: SuggestionSettingsModel
    private let foundationModelAvailabilityService: FoundationModelAvailabilityService
    private let learningModels: LearningModelCollection
    private let speech: LearningSpeechController
    private let endpointConnection: OpenAICompatibleConnectionModel
    private let searchService: HuggingFaceSearchService
    /// Installed once by the composition root after both window owners exist. Weak captures in
    /// those callbacks keep the windows as siblings rather than making a coordinator retain cycle.
    var openSettings: (SettingsItem) -> Void = { _ in }
    var openUsageGuide: () -> Void = {}
    var openVocabulary: () -> Void = {}
    private let userDefaults: UserDefaults

    private var welcomeWindowController: NSWindowController?
    private var permissionReminderWindowController: NSWindowController?

    /// Stamp completion for new users without forcing returning users through a refreshed flow.
    /// Manual reopening always observes their saved configuration rather than applying a preset.
    private static let currentOnboardingVersion = 2
    private static let deferredPermissionsKey = "lingroveOnboardingPermissionsDeferred"

    /// Stores the onboarding version the user last *completed* (reached "done" and dismissed), not a
    /// yes/no flag. An absent key reads as `0`, identifying a new or interrupted setup unless the
    /// older completed boolean is present.
    ///
    /// The older completed boolean is also respected. Merely having shown a welcome window is
    /// not completion, so the legacy presentation-only flag never bypasses an interrupted setup.
    private static let onboardingCompletedVersionKey = "lingroveOnboardingCompletedVersion"

    /// Furthest onboarding step the user has reached, stored as the step's raw index. Lets the wizard
    /// *resume* instead of restarting when the user is pulled out mid-flow: granting Accessibility or
    /// Input Monitoring on the permissions step typically only takes effect after the user quits and
    /// relaunches Lingrove, which lands before the final "Start Using Lingrove" tap that stamps
    /// completion. Without this, that relaunch drops them back at step one and onboarding repeats
    /// every time (issue #314). Cleared on completion so manual reopening starts clean.
    ///
    /// The "2" suffix marks the second step-numbering scheme (the redesign folded the writing-style
    /// step into "personalize", shifting every later raw index). Reading the old key would resume a
    /// mid-flow user onto the wrong step, so the old key is abandoned rather than reinterpreted;
    /// anyone caught mid-flow across the update restarts at the welcome step, which is the safe
    /// outcome. Any future change to `WelcomeStep`'s numbering must bump this suffix again.
    private static let onboardingProgressStepKey = "lingroveOnboardingProgressStep2"

    init(
        permissionManager: PermissionManager,
        permissionGuidanceController: PermissionGuidanceController,
        runtimeModel: RuntimeBootstrapModel,
        modelDownloadManager: ModelDownloadManager,
        suggestionSettings: SuggestionSettingsModel,
        foundationModelAvailabilityService: FoundationModelAvailabilityService,
        learningModels: LearningModelCollection,
        speech: LearningSpeechController,
        endpointConnection: OpenAICompatibleConnectionModel,
        searchService: HuggingFaceSearchService,
        userDefaults: UserDefaults = .standard
    ) {
        self.permissionManager = permissionManager
        self.permissionGuidanceController = permissionGuidanceController
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.suggestionSettings = suggestionSettings
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.learningModels = learningModels
        self.speech = speech
        self.endpointConnection = endpointConnection
        self.searchService = searchService
        self.userDefaults = userDefaults
    }

    /// Any completed version is sufficient. Product updates remain available through the manual
    /// entry point; first launch and an interrupted setup are the only automatic presentations.
    private var isOnboardingCompleted: Bool {
        !OnboardingSetupPolicy.shouldPresent(completedVersion: userDefaults.integer(forKey: Self.onboardingCompletedVersionKey),
            legacyCompleted: userDefaults.bool(forKey: "lingroveOnboardingCompleted"))
    }

    /// Presents the welcome wizard if the user has never completed onboarding.
    ///
    /// Unlike the previous approach, the completion flag is set when the user finishes the wizard
    /// (taps "Start Using Lingrove"), not when the window first appears. If the user closes the
    /// window mid-flow or macOS prompts a restart for permissions, the wizard will reappear on
    /// next launch so they don't lose their place.
    func presentIfNeeded() {
        guard !isOnboardingCompleted else {
            return
        }

        showWelcome()
    }

    /// Shows just the permission step when the user completed onboarding previously but one or
    /// more required permissions are now missing (e.g., after a permission-prompted restart, or
    /// if the user later revoked a permission in System Settings).
    func presentPermissionReminderIfNeeded() {
        if permissionManager.requiredPermissionsGranted {
            userDefaults.removeObject(forKey: Self.deferredPermissionsKey)
        }
        guard OnboardingSetupPolicy.shouldRemind(completed: isOnboardingCompleted,
            permissionsGranted: permissionManager.requiredPermissionsGranted,
            deferred: userDefaults.bool(forKey: Self.deferredPermissionsKey)),
            permissionReminderWindowController == nil else { return }

        showPermissionReminder()
    }

    /// Manual entry point for reopening the welcome screen later from the menu.
    func showWelcome() {
        if let window = welcomeWindowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let resumeStepIndex = userDefaults.integer(forKey: Self.onboardingProgressStepKey)

        let hostingController = NSHostingController(
            rootView: WelcomeView(
                permissionManager: permissionManager,
                runtimeModel: runtimeModel,
                modelDownloadManager: modelDownloadManager,
                suggestionSettings: suggestionSettings,
                foundationModelAvailabilityService: foundationModelAvailabilityService,
                permissionGuidanceController: permissionGuidanceController,
                onPreferredWindowSizeChange: { [weak self] size in
                    self?.resizeWelcomeWindow(to: size)
                },
                onDismiss: { [weak self] in
                    self?.completeOnboarding()
                },
                initialStepIndex: resumeStepIndex,
                isReturningUser: isOnboardingCompleted,
                modelConfiguration: { [weak self] navigation in self?.configuration(navigation) ?? AnyView(EmptyView()) },
                readiness: { [weak self] filename in self?.readiness(filename) ?? AnyView(EmptyView()) },
                openSettings: { [weak self] in self?.openSettings($0) },
                openUsageGuide: { [weak self] in self?.openUsageGuide() },
                openVocabulary: { [weak self] in self?.openVocabulary() },
                deferPermissions: { [weak self] in self?.userDefaults.set(true, forKey: Self.deferredPermissionsKey) },
                onStepChange: { [weak self] stepIndex in
                    self?.recordProgress(stepIndex: stepIndex)
                }
            )
        )

        // Size the window for the step the wizard actually opens on (the resume point, mirroring
        // WelcomeView's own fallback for out-of-range indices) so it never flashes at one size and
        // immediately animates to another.
        let initialStep = WelcomeStep(rawValue: resumeStepIndex) ?? .welcome

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: initialStep.preferredWindowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to Lingrove", table: "Learning")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentViewController = hostingController

        let windowController = NSWindowController(window: window)
        welcomeWindowController = windowController

        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// These forms borrow the process-lifetime services; wizard-local navigation only selects a
    /// page. Configuration and download behavior remain exactly the same as the Settings window.
    private func configuration(_ navigation: SettingsNavigationModel) -> AnyView {
        AnyView(EngineAndModelPaneView(showsTaskPicker: false, navigation: navigation,
            learningModels: learningModels, speech: speech, suggestionSettings: suggestionSettings,
            openAICompatibleConnectionModel: endpointConnection,
            foundationModelAvailabilityService: foundationModelAvailabilityService,
            runtimeModel: runtimeModel, modelDownloadManager: modelDownloadManager,
            huggingFaceSearchService: searchService))
    }

    private func readiness(_ filename: String?) -> AnyView {
        AnyView(WelcomeReadinessView(settings: suggestionSettings, permissions: permissionManager,
            runtime: runtimeModel, foundation: foundationModelAvailabilityService,
            connection: endpointConnection, downloads: modelDownloadManager,
            translation: learningModels.translation.profile, explanation: learningModels.explanation.profile,
            speech: speech.settings, translationController: learningModels.translation,
            explanationController: learningModels.explanation, speechController: speech,
            pendingCompletionModel: filename, open: { [weak self] in self?.openSettings($0) }))
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }

        if closingWindow == welcomeWindowController?.window {
            permissionGuidanceController.dismiss()
            welcomeWindowController = nil
        } else if closingWindow == permissionReminderWindowController?.window {
            permissionGuidanceController.dismiss()
            permissionReminderWindowController = nil
        }
    }

    /// Called when the user completes the full onboarding wizard ("Start Using Lingrove"). Stamps the
    /// completed version so product updates do not reopen setup automatically.
    /// This is the only thing that clears the gate: closing the window mid-flow leaves the stored
    /// version unchanged, so the wizard returns on next launch.
    private func completeOnboarding() {
        userDefaults.set(Self.currentOnboardingVersion, forKey: Self.onboardingCompletedVersionKey)
        // Drop the resume marker so reopening the wizard later (menu entry point, or a future version
        // bump re-showing it) starts from the welcome step rather than the last step of this run.
        userDefaults.removeObject(forKey: Self.onboardingProgressStepKey)
        permissionGuidanceController.dismiss()
        welcomeWindowController?.close()
    }

    /// Persists the furthest step the wizard has reached. Monotonic: a user stepping back never
    /// lowers the resume point, so closing the window always reopens at the deepest step they saw.
    private func recordProgress(stepIndex: Int) {
        guard stepIndex > userDefaults.integer(forKey: Self.onboardingProgressStepKey) else {
            return
        }
        userDefaults.set(stepIndex, forKey: Self.onboardingProgressStepKey)
    }

    private func showPermissionReminder() {
        let hostingController = NSHostingController(
            rootView: PermissionReminderView(
                permissionManager: permissionManager,
                permissionGuidanceController: permissionGuidanceController,
                onDismiss: { [weak self] in
                    self?.dismissPermissionReminder()
                }
            )
        )

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: NSSize(width: 540, height: 420)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Lingrove — Permissions", table: "Learning")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentViewController = hostingController

        let windowController = NSWindowController(window: window)
        permissionReminderWindowController = windowController

        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func dismissPermissionReminder() {
        permissionGuidanceController.dismiss()
        permissionReminderWindowController?.close()
    }

    /// Window sizing is an AppKit responsibility, so the SwiftUI onboarding view reports its
    /// preferred content size upward and the coordinator applies it here.
    ///
    /// We keep the window centered while resizing because onboarding is a modal-like flow; letting
    /// the frame grow down and to the right makes it feel jumpy and accidental.
    private func resizeWelcomeWindow(to contentSize: NSSize) {
        guard let window = welcomeWindowController?.window else {
            return
        }

        // Clamp the requested height so a tall step can never push the window taller than the screen,
        // which on smaller or scaled MacBook displays used to leave the bottom (and the Continue
        // button) off-screen with no way to reach it. The content scrolls to fill any shortfall.
        let clampedContentSize = clampedContentSize(contentSize, for: window)

        let currentContentSize = window.contentLayoutRect.size
        guard Swift.abs(currentContentSize.width - clampedContentSize.width) > 0.5
            || Swift.abs(currentContentSize.height - clampedContentSize.height) > 0.5 else {
            return
        }

        let targetWindowFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: clampedContentSize))
        let currentFrame = window.frame
        let centeredOrigin = NSPoint(
            x: currentFrame.midX - (targetWindowFrame.width / 2),
            y: currentFrame.midY - (targetWindowFrame.height / 2)
        )
        let centeredFrame = constrainedToScreen(
            NSRect(origin: centeredOrigin, size: targetWindowFrame.size),
            for: window
        )

        window.setFrame(centeredFrame.integral, display: true, animate: true)
    }

    /// Shrinks the requested content height to what fits within the active screen's visible frame
    /// (minus chrome and a margin). Width is left untouched.
    private func clampedContentSize(_ contentSize: NSSize, for window: NSWindow) -> NSSize {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return contentSize
        }

        let chromeHeight = window.frameRect(forContentRect: .zero).height
        let maxContentHeight = visibleFrame.height - chromeHeight - (Layout.screenEdgeMargin * 2)
        guard maxContentHeight > 0 else {
            return contentSize
        }

        return NSSize(width: contentSize.width, height: min(contentSize.height, maxContentHeight))
    }

    /// Nudges a proposed window frame so it stays fully within the visible screen after recentering.
    private func constrainedToScreen(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return frame
        }

        var origin = frame.origin
        origin.x = min(max(origin.x, visibleFrame.minX + Layout.screenEdgeMargin),
                       visibleFrame.maxX - frame.width - Layout.screenEdgeMargin)
        origin.y = min(max(origin.y, visibleFrame.minY + Layout.screenEdgeMargin),
                       visibleFrame.maxY - frame.height - Layout.screenEdgeMargin)

        return NSRect(origin: origin, size: frame.size)
    }
}
