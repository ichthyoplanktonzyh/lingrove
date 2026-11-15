import CoreGraphics

/// Snapshot of the key data `InputMonitor` needs after a raw `CGEvent` enters the tap callback.
///
/// Keeping this as a tiny value type lets unit tests exercise tap ownership without constructing
/// synthetic CoreGraphics events. That matters because app-hosted macOS tests can crash in CGEvent
/// allocation/teardown even when the production code path is correct.
nonisolated struct InputMonitorKeyEvent: Sendable {
    let keyCode: CGKeyCode
    let characters: String
    let flags: CGEventFlags
    /// Mirrors `kCGKeyboardEventAutorepeat`: the key is being held, not pressed again.
    let isAutorepeat: Bool

    init(keyCode: CGKeyCode, characters: String = "", flags: CGEventFlags = [], isAutorepeat: Bool = false) {
        self.keyCode = keyCode
        self.characters = characters
        self.flags = flags
        self.isAutorepeat = isAutorepeat
    }
}

/// The consuming tap has three possible outcomes for a key-down event.
///
/// `notHandled` means the key was not one of Lingrove's configured accept keys. `passThrough`
/// means it was an accept key but Lingrove declined to consume it. `consume` means the coordinator
/// accepted successfully and the original key event should be swallowed.
nonisolated enum InputMonitorAcceptTapDecision: Equatable, Sendable {
    case notHandled
    case passThrough
    case consume
}
