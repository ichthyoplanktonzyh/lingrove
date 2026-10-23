import Testing
@testable import Cotabby

@MainActor
struct SuggestionVisualActivityTests {
    @Test func onlyEligibleEditingKeysRenewVisualActivity() {
        let rig = makeCoordinatorRig()
        rig.permissionProvider.screenRecordingGranted = true
        defer { rig.coordinator.stop() }
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .other))
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .dismissal))
        #expect(rig.visualContext.inputActivity.isEmpty)
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "a"))
        #expect(rig.visualContext.inputActivity.count == 1)
        rig.permissionProvider.screenRecordingGranted = false
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "b"))
        #expect(rig.visualContext.inputActivity.count == 1)
    }
}
