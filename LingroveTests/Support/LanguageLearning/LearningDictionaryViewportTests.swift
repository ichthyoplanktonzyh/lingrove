import Testing
@testable import Lingrove

struct LearningDictionaryViewportTests {
    @Test func firstResolvedSourceLocksItsViewportAndNewWordStartsCompact() {
        var viewport = LearningDictionaryViewport()
        viewport.measure(20, query: "posted", resolved: false)
        viewport.measure(150, query: "posted", resolved: true)
        viewport.measure(2_000, query: "posted", resolved: true)
        viewport.measure(20, query: "posted", resolved: false)
        #expect(viewport.height(for: "posted") == 150)
        #expect(viewport.height(for: "progress") == 120)
        viewport.measure(2_000, query: "progress", resolved: true)
        #expect(viewport.height(for: "progress") == 300)
    }

    @Test func unmeasuredHTMLAndErrorsDoNotLockTheFirstSuccessfulDefinition() {
        var viewport = LearningDictionaryViewport()
        viewport.measure(120, query: "word", resolved: false)
        viewport.measure(260, query: "word", resolved: true)
        #expect(viewport.height(for: "word") == 260)
        viewport.measure(.nan, query: "other", resolved: true)
        #expect(viewport.height(for: "word") == 260)
    }
}
