import AppKit
import Logging

/// One detail-card host owns this weak registry. SwiftUI can temporarily detach a popover from
/// its AppKit parent; its content view still knows the exact window receiving the click.
/// Replacing the host replaces the registry, so late teardown cannot register an old capture
/// as part of a new card. No frame-only exemption or other app window is trusted here.
@MainActor
final class LearningPopupWindowRegistry {
    private final class Reference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private var references: [UUID: Reference] = [:]

    var windows: [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        return references.values.compactMap(\.window).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    func update(_ window: NSWindow?, for token: UUID) {
        if let window { references[token] = Reference(window) } else { references.removeValue(forKey: token) }
        CotabbyLogger.learning.debug("Learning popover membership changed", metadata: [
            "stage": "popover-membership", "registration_id": .string(token.uuidString),
            "window_number": .stringConvertible(window?.windowNumber ?? 0),
            "parent_window_number": .stringConvertible(window?.parent?.windowNumber ?? 0)
        ])
    }

    func owns(_ window: NSWindow?) -> Bool {
        let registered = windows.filter { $0.isVisible && !$0.ignoresMouseEvents }
        var current = window
        while let candidate = current {
            if registered.contains(where: { $0 === candidate }) { return true }
            current = candidate.parent
        }
        return false
    }

    func reset() { references.removeAll() }
}
