import Foundation

/// A field session's refresh budget follows actual editing activity, not AX polling or model
/// output. VisualContextCoordinator owns this tiny value and supplies monotonic uptime. It adds
/// no timer; the existing refresh checks it and stops rearming when the editing window expires.
nonisolated struct VisualContextActivity {
    let idleInterval: TimeInterval
    private var lastActivity: TimeInterval?

    init(idleInterval: TimeInterval = 10) { self.idleInterval = idleInterval }

    mutating func record(at uptime: TimeInterval) { lastActivity = uptime }
    mutating func reset() { lastActivity = nil }

    func allowsRefresh(at uptime: TimeInterval) -> Bool {
        guard let lastActivity else { return false }
        return uptime - lastActivity < idleInterval
    }
}
