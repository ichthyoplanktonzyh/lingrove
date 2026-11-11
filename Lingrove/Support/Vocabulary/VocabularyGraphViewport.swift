import CoreGraphics

/// Cheap rejection before AppKit allocates/strokes a path. Tree Bézier control points lie
/// inside the endpoints' rectangle; the generous margin retains labels, arrowheads and glow.
nonisolated enum VocabularyGraphViewport {
    static func containsEdge(from start: CGPoint, to end: CGPoint, viewport: CGRect) -> Bool {
        let area = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
            width: max(1, abs(start.x - end.x)), height: max(1, abs(start.y - end.y)))
        return area.intersects(viewport.insetBy(dx: -160, dy: -55))
    }
}
