import Testing
@testable import Cotabby

struct VisualContextActivityTests {
    @Test func activityExpiresAtTheIdleBoundaryAndCanResume() {
        var activity = VisualContextActivity()
        #expect(!activity.allowsRefresh(at: 100))
        activity.record(at: 100)
        #expect(activity.allowsRefresh(at: 109.99))
        #expect(!activity.allowsRefresh(at: 110))
        activity.record(at: 110)
        #expect(activity.allowsRefresh(at: 119.99))
        activity.reset()
        #expect(!activity.allowsRefresh(at: 110))
    }
}
