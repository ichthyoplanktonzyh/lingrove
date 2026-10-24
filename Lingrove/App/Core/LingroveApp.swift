import SwiftUI

/// File overview:
/// Declares the SwiftUI app entry point and standard app commands. AppDelegate owns the
/// native status item/popover and injects the existing services into its hosted SwiftUI pages.
///
/// `@main` marks the single process entry point for a Swift app.
@main
struct LingroveApp: App {
    /// Bridges old-style AppKit lifecycle callbacks into a SwiftUI app.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Settings supplies the standard app command scene. The existing SettingsCoordinator owns
    /// the real settings window; AppDelegate owns the native status item and popover separately.
    var body: some Scene {
        Settings { EmptyView() }
        .commands {
            // Route the standard command to the same app-owned Settings window as the status item;
            // the command scene must not create a second set of settings or services.
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "Settings") + "…") {
                    guard !AppDelegate.isRunningForPreviews else { return }
                    appDelegate.settingsCoordinator.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button(String(localized: "Vocabulary", table: "Vocabulary")) {
                    guard !AppDelegate.isRunningForPreviews else { return }
                    appDelegate.vocabularyWindow.show()
                }
            }
        }
    }
}
