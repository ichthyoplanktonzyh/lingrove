import Foundation

/// Deterministic setup rules shared by the window lifecycle and its status rows. No rule starts
/// a runtime or changes preferences: a selected file can be configured while its weights stay cold.
enum OnboardingSetupPolicy {
    enum ModelStatus: Equatable {
        case needsConfiguration, downloading, configured, unavailable
    }

    static func modelStatus(selected: Bool, available: Bool, downloading: Bool = false) -> ModelStatus {
        if downloading { return .downloading }
        guard selected else { return .needsConfiguration }
        return available ? .configured : .unavailable
    }

    /// Existing users can reopen setup themselves; a content refresh must not restart their wizard.
    static func shouldPresent(completedVersion: Int, legacyCompleted: Bool = false) -> Bool {
        completedVersion == 0 && !legacyCompleted
    }

    static func shouldRemind(completed: Bool, permissionsGranted: Bool, deferred: Bool) -> Bool {
        completed && !permissionsGranted && !deferred
    }
}
