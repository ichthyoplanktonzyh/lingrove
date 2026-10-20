import CoreGraphics

/// One card owns this small geometry state for its current query. The first completed
/// definition chooses a compact 120–300pt viewport; later providers scroll inside it.
/// Loading/errors never lock the viewport, and a different word starts a fresh measurement.
nonisolated struct LearningDictionaryViewport {
    private var query: String?
    private var height: CGFloat = 120
    private var locked = false

    func height(for query: String) -> CGFloat { self.query == query ? height : 120 }

    mutating func measure(_ naturalHeight: CGFloat, query: String, resolved: Bool) {
        guard naturalHeight.isFinite, naturalHeight > 0 else { return }
        if self.query != query { self.query = query; locked = false }
        guard !locked else { return }
        height = min(300, max(120, ceil(naturalHeight)))
        locked = resolved
    }
}
