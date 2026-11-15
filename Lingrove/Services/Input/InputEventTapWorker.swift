import CoreGraphics
import Foundation
import Logging

/// Owns one Quartz event tap and its dedicated native run loop for an `InputMonitor` lifetime.
/// Ordinary input returns immediately and is observed later on the main queue. Only a key named
/// in the routing snapshot waits for the existing main-actor consume/insert transaction.
///
/// One ordered delivery stream is important: emoji/macro observation prepares the decision for
/// the very same key. Separate observer and consuming taps on different run loops would race.
/// `@unchecked Sendable` is limited to this OS boundary: routing/run-loop publication is locked;
/// the mach port itself is accessed only by its owning thread. No lock is held during delivery.
nonisolated final class InputEventTapWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var routing: InputEventTapRouting
    private var runLoop: CFRunLoop?
    private var hasStarted = false
    private var isStopped = false
    private var installationFailed = false
    // Only the dedicated thread reads/writes this port, including timeout recovery and teardown.
    private var tap: CFMachPort?
    private let deliver: @MainActor @Sendable (InputEventTapDelivery, Bool) -> Bool

    init(
        routing: InputEventTapRouting,
        deliver: @escaping @MainActor @Sendable (InputEventTapDelivery, Bool) -> Bool
    ) {
        self.routing = routing
        self.deliver = deliver
    }

    /// Starts asynchronously. The main actor must never join this thread: it may be confirming an
    /// acceptance on the main queue. The thread retains its worker until native teardown completes.
    func start() {
        lock.lock()
        guard !hasStarted, !isStopped else { lock.unlock(); return }
        hasStarted = true
        lock.unlock()
        let thread = Thread { [self] in run() }
        thread.name = "Lingrove.InputEventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func updateRouting(_ routing: InputEventTapRouting) {
        lock.lock()
        if !isStopped { self.routing = routing }
        lock.unlock()
    }

    /// Permission refresh may retry a failed installation without leaking another native thread.
    var didFailToInstall: Bool {
        lock.lock()
        defer { lock.unlock() }
        return installationFailed
    }

    /// Fails open immediately, drops queued observations, then retires the native port on its own
    /// run loop. Scheduling a stop block also handles stop racing the run loop's first entry.
    func stop() {
        lock.lock()
        isStopped = true
        routing.isMonitoring = false
        let loop = runLoop
        lock.unlock()
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
    }

    private func routingSnapshot() -> InputEventTapRouting {
        lock.lock()
        defer { lock.unlock() }
        return routing
    }

    /// Production and regression tests share this exact dispatch path. In particular, the normal
    /// branch must never wait for the main queue, even when that queue is blocked by an AX call.
    @discardableResult
    func dispatch(_ delivery: InputEventTapDelivery) -> Bool {
        let snapshot = routingSnapshot()
        guard snapshot.isMonitoring else { return false }
        let needsDecision: Bool
        switch delivery {
        case let .key(event, isSynthetic):
            needsDecision = snapshot.needsDecision(for: event, isSynthetic: isSynthetic)
        case .pointer:
            needsDecision = false
        }
        if needsDecision {
            // Only candidate shortcuts enter this synchronous bridge. Keeping the original key
            // pending until the coordinator answers preserves "successful insertion AND consume",
            // including IME/paste insertion and the last chunk of a rapid Tab acceptance burst.
            return DispatchQueue.main.sync { [self] in
                MainActor.assumeIsolated {
                    guard routingSnapshot().isMonitoring else { return false }
                    return deliver(delivery, true)
                }
            }
        }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard routingSnapshot().isMonitoring else { return }
                _ = deliver(delivery, false)
            }
        }
        return false
    }

    private func run() {
        autoreleasepool {
            let callback: CGEventTapCallBack = { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                // The running thread retains the worker until after the port is invalidated.
                let worker = Unmanaged<InputEventTapWorker>.fromOpaque(userInfo).takeUnretainedValue()
                // This native run loop may live for days. Drain temporary Foundation objects per
                // callback rather than retaining an entire typing session's autoreleased values.
                return autoreleasepool { worker.handle(type: type, event: event) }
            }
            let mask = (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                lock.lock()
                installationFailed = true
                lock.unlock()
                LingroveLogger.app.warning("Failed to create input-thread event tap; Input Monitoring may be missing")
                return
            }
            tap = port
            let loop = CFRunLoopGetCurrent()!
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
            CFRunLoopAddSource(loop, source, .defaultMode)
            defer {
                CFMachPortInvalidate(port)
                CFRunLoopRemoveSource(loop, source, .defaultMode)
                tap = nil
                lock.lock()
                runLoop = nil
                lock.unlock()
                LingroveLogger.app.info("Input-thread event tap stopped")
            }
            lock.lock()
            runLoop = loop
            let shouldRun = !isStopped
            lock.unlock()
            guard shouldRun else { return }
            CGEvent.tapEnable(tap: port, enable: true)
            LingroveLogger.app.info("Input-thread event tap installed (ordinary keys bypass main actor)")
            CFRunLoopRun()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap, routingSnapshot().isMonitoring { CGEvent.tapEnable(tap: tap, enable: true) }
            LingroveLogger.app.warning("Input-thread event tap was disabled by system")
        case .keyDown:
            let key = InputMonitorKeyEvent(keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                characters: event.lingroveUnicodeString, flags: event.flags,
                isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            let synthetic = event.getIntegerValueField(.eventSourceUserData) == InputSuppressionController.syntheticEventUserData
            if dispatch(.key(key, isSynthetic: synthetic)) { return nil }
        case .leftMouseDown, .rightMouseDown:
            dispatch(.pointer(event.location))
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

private extension CGEvent {
    nonisolated var lingroveUnicodeString: String {
        // Keyboard payloads are normally one UTF-16 unit, but a composing IME may supply more.
        // Copy while the callback owns the event; no pointer or event reference escapes this scope.
        var length = 0
        keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return "" }
        var buffer = [UniChar](repeating: 0, count: length)
        keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }
}
