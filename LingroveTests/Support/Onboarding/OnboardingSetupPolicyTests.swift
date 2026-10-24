import Testing
@testable import Lingrove

/// Setup may finish before permissions or downloads do. These cases protect returning users and
/// cold-but-configured models from being treated as a new install or a running inference session.
@MainActor
struct OnboardingSetupPolicyTests {
    @Test func anUpgradeDoesNotForceACompletedUserBackIntoSetup() {
        #expect(OnboardingSetupPolicy.shouldPresent(completedVersion: 0))
        #expect(!OnboardingSetupPolicy.shouldPresent(completedVersion: 1))
        #expect(!OnboardingSetupPolicy.shouldPresent(completedVersion: 2))
        #expect(!OnboardingSetupPolicy.shouldPresent(completedVersion: 99))
        #expect(!OnboardingSetupPolicy.shouldPresent(completedVersion: 0, legacyCompleted: true))
    }

    @Test func deferringPermissionsDoesNotTurnCompletionIntoAnImmediateReminderLoop() {
        #expect(!OnboardingSetupPolicy.shouldRemind(completed: false, permissionsGranted: false, deferred: false))
        #expect(!OnboardingSetupPolicy.shouldRemind(completed: true, permissionsGranted: false, deferred: true))
        #expect(!OnboardingSetupPolicy.shouldRemind(completed: true, permissionsGranted: true, deferred: false))
        #expect(OnboardingSetupPolicy.shouldRemind(completed: true, permissionsGranted: false, deferred: false))
    }

    @Test func configurationIsDistinctFromLoadingAndMissingFiles() {
        #expect(OnboardingSetupPolicy.modelStatus(selected: false, available: false) == .needsConfiguration)
        #expect(OnboardingSetupPolicy.modelStatus(selected: true, available: false) == .unavailable)
        #expect(OnboardingSetupPolicy.modelStatus(selected: true, available: true) == .configured)
        #expect(OnboardingSetupPolicy.modelStatus(selected: false, available: false, downloading: true) == .downloading)
    }
}
