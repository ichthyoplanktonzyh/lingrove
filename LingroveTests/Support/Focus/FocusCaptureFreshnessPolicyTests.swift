import Testing
@testable import Lingrove

struct FocusCaptureFreshnessPolicyTests {
    @Test func preInputReadCannotBecomeFreshByCompletingAfterTheKey() {
        #expect(!FocusCaptureFreshnessPolicy.canReuseAfterInput(captureStartedAt: 99, inputAt: 100,
            ageMilliseconds: 0, maxAgeMilliseconds: 30, sameIdentity: true))
        #expect(FocusCaptureFreshnessPolicy.canReuseAfterInput(captureStartedAt: 101, inputAt: 100,
            ageMilliseconds: 5, maxAgeMilliseconds: 30, sameIdentity: true))
    }

    @Test func changedFocusAndExpiredOrUnknownCapturesRequireAnotherRead() {
        #expect(!FocusCaptureFreshnessPolicy.canReuseAfterInput(captureStartedAt: 101, inputAt: 100,
            ageMilliseconds: 5, maxAgeMilliseconds: 30, sameIdentity: false))
        #expect(!FocusCaptureFreshnessPolicy.canReuseAfterInput(captureStartedAt: 101, inputAt: 100,
            ageMilliseconds: 31, maxAgeMilliseconds: 30, sameIdentity: true))
        #expect(!FocusCaptureFreshnessPolicy.canReuseAfterInput(captureStartedAt: nil, inputAt: 100,
            ageMilliseconds: 0, maxAgeMilliseconds: 30, sameIdentity: true))
        #expect(!FocusCaptureFreshnessPolicy.canReuseAfterInput(captureStartedAt: 101, inputAt: 100,
            ageMilliseconds: nil, maxAgeMilliseconds: 30, sameIdentity: true))
    }

    @Test func timerSkipsOnlyWithinOneBaseIntervalOfARealCapture() {
        #expect(FocusCaptureFreshnessPolicy.shouldSkipTimerCapture(completedAt: 100, now: 149, intervalNanoseconds: 50))
        #expect(!FocusCaptureFreshnessPolicy.shouldSkipTimerCapture(completedAt: 100, now: 150, intervalNanoseconds: 50))
        #expect(!FocusCaptureFreshnessPolicy.shouldSkipTimerCapture(completedAt: nil, now: 149, intervalNanoseconds: 50))
        #expect(!FocusCaptureFreshnessPolicy.shouldSkipTimerCapture(completedAt: 150, now: 149, intervalNanoseconds: 50))
    }
}
