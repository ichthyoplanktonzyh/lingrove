import Testing
@testable import Lingrove

struct ScreenshotDebugGateTests {
    @Test(arguments: [([], false), (["-lingrove-debug"], false),
        (["-lingrove-debug-screenshots"], false),
        (["-lingrove-debug", "-lingrove-debug-screenshots"], true)])
    func screenshotsRequireBothExplicitSwitches(example: ([String], Bool)) {
        #expect(LingroveDebugOptions.shouldCaptureScreenshots(arguments: example.0) == example.1)
    }
}
