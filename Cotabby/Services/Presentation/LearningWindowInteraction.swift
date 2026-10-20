import AppKit

/// Stateless AppKit boundary shared by writing and reading cards. Native lookup content can
/// deliver events through another process, so a global event has no usable local NSWindow.
/// Match Window Server's frontmost hit to a visible member of our window family instead of
/// assuming that every global event is outside. The hit number is injected for deterministic tests.
@MainActor
enum LearningWindowInteraction {
    static func contains(_ point: CGPoint, roots: [NSWindow?], hitWindowNumber: Int) -> Bool {
        guard point.x.isFinite, point.y.isFinite, hitWindowNumber > 0 else { return false }
        var pending = roots.compactMap { $0 }
        var visited = Set<ObjectIdentifier>()
        while let window = pending.popLast() {
            guard visited.insert(ObjectIdentifier(window)).inserted else { continue }
            if window.isVisible, !window.ignoresMouseEvents, window.windowNumber == hitWindowNumber,
               window.frame.contains(point) { return true }
            pending.append(contentsOf: window.childWindows ?? [])
        }
        return false
    }
}
