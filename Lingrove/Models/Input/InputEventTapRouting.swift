import CoreGraphics
import Foundation

/// A physical key and its normalized modifiers, copied from main-actor settings into the input
/// thread's routing snapshot. It contains no observable model or provider closure, so matching an
/// ordinary key never needs to enter the main actor. An unbound (`.max`) key never matches.
nonisolated struct InputKeyBinding: Hashable, Sendable {
    let keyCode: CGKeyCode
    let modifiers: ShortcutModifierMask

    init(_ keyCode: CGKeyCode, _ modifiers: ShortcutModifierMask = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    func matches(_ event: InputMonitorKeyEvent) -> Bool {
        keyCode != .max && keyCode == event.keyCode
            && modifiers == ShortcutModifierMask(eventFlags: event.flags)
    }
}

/// Immutable, conservative prefilter published by `InputMonitor`. The worker only asks whether a
/// key *might* be consumed; the main-actor coordinator still decides whether it actually may be.
/// Stale routing can therefore request an unnecessary confirmation, but cannot authorize insertion.
/// Key-code-only entries cover panel Escape/Return/navigation, whose handling ignores modifiers.
nonisolated struct InputEventTapRouting: Sendable {
    var isMonitoring = false
    /// Only an explicitly open screen-region selector owns all keys. Normal writing never does.
    var isModalCapture = false
    var decisionBindings: Set<InputKeyBinding> = []
    var decisionKeyCodes: Set<CGKeyCode> = []

    func needsDecision(for event: InputMonitorKeyEvent, isSynthetic: Bool) -> Bool {
        isMonitoring && !isSynthetic
            && (isModalCapture || decisionKeyCodes.contains(event.keyCode) || decisionBindings.contains { $0.matches(event) })
    }
}

/// Owned by the event callback until it has copied the event's scalar/string data. Raw `CGEvent`
/// references never cross threads or outlive their callback; queued main-actor delivery owns this
/// value instead. Synthetic identity is preserved independently of suppression countdown timing.
nonisolated enum InputEventTapDelivery: Sendable {
    case key(InputMonitorKeyEvent, isSynthetic: Bool)
    case pointer(CGPoint)
}
