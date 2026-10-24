import Foundation

/// Pure permission for observing a saved editor during the panel's explicit activation round trip.
/// The editor and panel controller borrow this rule; it grants no permission to write or to
/// reactivate an app after the user has moved elsewhere. The coordinator owns the session lifetime.
nonisolated enum ExpressionAssistFocusPolicy {
    static func permitsHostRead(frontmost: pid_t?, host: pid_t, inputOwner: pid_t, inputOwnsKeyboard: Bool) -> Bool {
        frontmost == host || (frontmost == inputOwner && inputOwnsKeyboard)
    }

    static func shouldRestoreHost(frontmost: pid_t?, host: pid_t, inputOwner: pid_t, inputOwnsKeyboard: Bool) -> Bool {
        host != inputOwner && frontmost == inputOwner && inputOwnsKeyboard
    }
}
