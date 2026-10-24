import Testing
@testable import Lingrove

@MainActor
struct SuggestionVisualActivityTests {
    @Test func onlyEligibleEditingKeysRenewVisualActivity() {
        let rig = makeCoordinatorRig()
        rig.permissionProvider.screenRecordingGranted = true
        defer { rig.coordinator.stop() }
        _ = rig.coordinator.handleInputEvent(LingroveTestFixtures.inputEvent(kind: .other))
        _ = rig.coordinator.handleInputEvent(LingroveTestFixtures.inputEvent(kind: .dismissal))
        #expect(rig.visualContext.inputActivity.isEmpty)
        _ = rig.coordinator.handleInputEvent(LingroveTestFixtures.inputEvent(kind: .textMutation, characters: "a"))
        #expect(rig.visualContext.inputActivity.count == 1)
        rig.permissionProvider.screenRecordingGranted = false
        _ = rig.coordinator.handleInputEvent(LingroveTestFixtures.inputEvent(kind: .textMutation, characters: "b"))
        #expect(rig.visualContext.inputActivity.count == 1)
    }
}
