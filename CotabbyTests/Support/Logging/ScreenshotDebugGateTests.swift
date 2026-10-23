import Testing
@testable import Cotabby

struct ScreenshotDebugGateTests {
    @Test(arguments: [([], false), (["-cotabby-debug"], false),
        (["-cotabby-debug-screenshots"], false),
        (["-cotabby-debug", "-cotabby-debug-screenshots"], true)])
    func screenshotsRequireBothExplicitSwitches(example: ([String], Bool)) {
        #expect(CotabbyDebugOptions.shouldCaptureScreenshots(arguments: example.0) == example.1)
    }
}
