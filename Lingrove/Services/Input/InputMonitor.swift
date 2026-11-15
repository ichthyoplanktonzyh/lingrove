import ApplicationServices
import Foundation
import Logging

/// Main-actor input facade owned by `LingroveAppEnvironment`. It keeps settings providers,
/// suppression, inline-feature arbitration and successful-insertion decisions beside their UI
/// owners. `InputEventTapWorker` owns the actual Quartz tap on a separate thread, so these owners
/// may be busy with Accessibility without delaying ordinary typing in another app.
///
/// Routing snapshots are only a prefilter. The live providers and coordinator remain the authority
/// for consuming a candidate key; observing and deciding that key run in one ordered transaction.
@MainActor
final class InputMonitor {
    var onEvent: ((CapturedInputEvent) -> Bool)?
    var onSuppressedSyntheticInput: (() -> Void)?
    var onPointerDown: (@MainActor (CGPoint) -> Void)?
    var learningKeyDecider: (@MainActor (InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision)?
    /// Retires reading receipts after ordinary host input without invoking any shortcut command.
    var onPassedThroughLearningInput: (@MainActor () -> Void)?
    var emojiCaptureKeyDecider: (@MainActor (InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision)?

    /// The composition root supplies physical learning bindings, not feature/model objects. All
    /// final availability/conflict checks still happen in `learningKeyDecider` for a matching key.
    var learningBindingsProvider: @MainActor () -> [InputKeyBinding] = { [] }
    var acceptanceBindingProvider: @MainActor () -> (keyCode: CGKeyCode, modifiers: ShortcutModifierMask) = { (48, []) }
    var fullAcceptanceBindingProvider: @MainActor () -> (keyCode: CGKeyCode, modifiers: ShortcutModifierMask) = { (.max, []) }
    var globalToggleKeyCodeProvider: @MainActor () -> CGKeyCode = { .max }
    var globalToggleKeyModifiersProvider: @MainActor () -> ShortcutModifierMask = { [] }
    var onGlobalToggleHotkey: (@MainActor () -> Void)?
    var shouldProcessEventsProvider: @MainActor () -> Bool = { true }
    var shouldConsumeAcceptKeyProvider: @MainActor @Sendable () -> Bool = { false }

    private let permissionProvider: @MainActor () -> Bool
    private let suppressionController: InputSuppressionController
    private var worker: InputEventTapWorker?
    private var hasStarted = false
    private var routingRefreshPending = false
    private var learningInterceptionActive = false
    private var modalInterceptionActive = false
    private var suggestionInterceptionActive = false
    // Internal semantic seams let tests stage capture ownership without installing a global tap.
    var isAcceptTapOwningAcceptKeys = false
    var captureInterceptionActive = false

    init(permissionProvider: @escaping @MainActor () -> Bool, suppressionController: InputSuppressionController) {
        self.permissionProvider = permissionProvider
        self.suppressionController = suppressionController
    }

    func start() {
        hasStarted = true
        refresh()
    }

    func stop() {
        hasStarted = false
        isAcceptTapOwningAcceptKeys = false
        worker?.stop()
        worker = nil
    }

    /// Permission restoration creates a new native lifetime. Shutdown never joins the worker:
    /// joining from this actor could deadlock an in-flight candidate-key confirmation.
    func refresh() {
        guard hasStarted, permissionProvider() else {
            worker?.stop()
            worker = nil
            isAcceptTapOwningAcceptKeys = false
            return
        }
        updateAcceptTapState()
        if worker?.didFailToInstall == true {
            worker?.stop()
            worker = nil
        }
        if worker == nil {
            let worker = InputEventTapWorker(routing: routingSnapshot()) { [weak self] delivery, mayConsume in
                self?.handleDelivery(delivery, mayConsume: mayConsume) ?? false
            }
            self.worker = worker
            worker.start()
        }
    }

    /// `@Published` sends before its backing property changes. Coalescing refreshes onto the next
    /// main-queue turn reads the completed settings/focus mutation, once per burst of changes.
    func scheduleRoutingRefresh() {
        guard !routingRefreshPending else { return }
        routingRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.routingRefreshPending = false
            self.worker?.updateRouting(self.routingSnapshot())
        }
    }

    func setAcceptInterceptionActive(_ active: Bool) {
        suggestionInterceptionActive = active
        updateAcceptTapState()
    }

    func setCaptureInterceptionActive(_ active: Bool) {
        captureInterceptionActive = active
        updateAcceptTapState()
    }

    func setLearningInterceptionActive(_ active: Bool) {
        learningInterceptionActive = active
        updateAcceptTapState()
    }

    func setModalInterceptionActive(_ active: Bool) {
        modalInterceptionActive = active
        updateAcceptTapState()
    }

    private func updateAcceptTapState() {
        isAcceptTapOwningAcceptKeys = hasStarted && permissionProvider() && suggestionInterceptionActive
        worker?.updateRouting(routingSnapshot())
    }

    /// Ordinary characters are absent unless the user explicitly bound that character to an active
    /// action. Caps lock/fn bits are normalized by `InputKeyBinding`, exactly like live arbitration.
    func routingSnapshot() -> InputEventTapRouting {
        var routing = InputEventTapRouting(isMonitoring: hasStarted && permissionProvider())
        guard routing.isMonitoring else { return routing }
        routing.isModalCapture = modalInterceptionActive
        routing.decisionBindings.insert(InputKeyBinding(globalToggleKeyCodeProvider(), globalToggleKeyModifiersProvider()))
        let learningBindings = learningBindingsProvider()
        if learningInterceptionActive || !learningBindings.isEmpty {
            routing.decisionBindings.formUnion(learningBindings)
            // Learning cards consume Escape for dismissal. Return remains ordinary host input
            // unless it is itself a configured shortcut or an active acceptance binding.
            routing.decisionKeyCodes.insert(53)
        }
        if shouldProcessEventsProvider() {
            if suggestionInterceptionActive || captureInterceptionActive {
                let binding = acceptanceBindingProvider()
                routing.decisionBindings.insert(InputKeyBinding(binding.keyCode, binding.modifiers))
            }
            if suggestionInterceptionActive {
                let binding = fullAcceptanceBindingProvider()
                routing.decisionBindings.insert(InputKeyBinding(binding.keyCode, binding.modifiers))
            }
            if captureInterceptionActive { routing.decisionKeyCodes.formUnion([53, 123, 124, 125, 126]) }
        }
        return routing
    }

    /// A candidate's observation and consumption share this main-queue call. In particular, an
    /// emoji commit may hide its own panel during observation; its pending decision still belongs
    /// to this exact key. Quartz retains the one native tap through final-chunk synthetic delivery.
    func handleDelivery(_ delivery: InputEventTapDelivery, mayConsume: Bool) -> Bool {
        guard hasStarted, permissionProvider() else { return false }
        switch delivery {
        case let .pointer(point):
            handleObserverPointerDown(at: point)
            return false
        case let .key(event, isSynthetic):
            return handleKeyDelivery(event, isSynthetic: isSynthetic, mayConsume: mayConsume)
        }
    }

    /// Semantic seam for the ordered main-actor transaction; tests do not install native taps.
    func handleKeyDelivery(_ event: InputMonitorKeyEvent, isSynthetic: Bool, mayConsume: Bool) -> Bool {
        if isSynthetic {
            _ = suppressionController.consumeIfNeeded()
            onSuppressedSyntheticInput?()
            return false
        }
        if mayConsume, event.keyCode == globalToggleKeyCodeProvider(), event.keyCode != .max,
           ShortcutModifierMask(eventFlags: event.flags) == globalToggleKeyModifiersProvider() {
            onGlobalToggleHotkey?()
            return true
        }
        let suppressObservation = suppressionController.consumeIfNeeded()
        if suppressObservation {
            onSuppressedSyntheticInput?()
        }
        if !suppressObservation, shouldProcessEventsProvider() {
            // A key already passed through by the worker must stay ordinary input even if an
            // overlay became visible before its queued observation reached the main actor.
            _ = routeObserverKeyDown(event, mayRecognizeAcceptance: mayConsume)
        }
        guard mayConsume else {
            onPassedThroughLearningInput?()
            return false
        }
        // The old observer's countdown did not suppress the separate accepting tap. Keep that
        // distinction: a rapid physical Tab may precede the synthetic events that own its tokens.
        // Only the explicit synthetic identity above is allowed to bypass acceptance itself.
        return resolveAcceptKeyDown(event) == .consume
    }

    /// Testable pointer observation, always delivered asynchronously by the worker.
    ///
    /// Production enters through `handleDelivery`; accepting a value here lets tests verify that
    /// pointer coordinates reach compatibility guards without allocating a CoreGraphics event in the
    /// app-hosted test process.
    func handleObserverPointerDown(at point: CGPoint) {
        onPointerDown?(point)
    }

    /// Testable observer path for semantic key snapshots.
    ///
    /// Production enters through `handleDelivery`; this method exists so tests can verify
    /// ownership rules without depending on CoreGraphics event allocation.
    func handleObserverKeyDown(_ keyEvent: InputMonitorKeyEvent) -> CapturedInputEvent? {
        guard shouldProcessEventsProvider() else {
            return nil
        }
        return routeObserverKeyDown(keyEvent)
    }

    /// Testable resolution of a keydown at the active tap: the emoji decider wins while a capture is
    /// open, otherwise the suggestion accept-key logic decides. `.notHandled` from the emoji decider
    /// means no capture is active, so the accept-key path takes over, without CGEvent allocation.
    func resolveAcceptKeyDown(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        // Reading can be explicitly allowed in an app where autocomplete is off. Learning owns
        // its own global/pause/permission/App checks; the autocomplete gate must not hide its key.
        if let decision = learningKeyDecider?(keyEvent), decision != .notHandled {
            return decision
        }
        guard shouldProcessEventsProvider() else { return .passThrough }
        if let emojiCaptureKeyDecider {
            let decision = emojiCaptureKeyDecider(keyEvent)
            if decision != .notHandled {
                return decision
            }
        }
        return handleAcceptKeyDown(keyEvent)
    }

    /// Testable accept-tap path for semantic key snapshots.
    ///
    /// Returning a decision instead of a CoreGraphics callback result keeps the ownership rule easy
    /// to test: a successful coordinator accept is the only path that consumes the original key.
    func handleAcceptKeyDown(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        guard shouldProcessEventsProvider() else {
            return .passThrough
        }

        guard let kind = acceptanceKind(for: keyEvent) else {
            return .notHandled
        }

        // Fail open. A stale accept tap with no visible suggestion should never steal the user's
        // key. When a visible overlay exists, the coordinator remains the final validator and can
        // clean up stale UI before this method passes the original key through.
        guard shouldConsumeAcceptKeyProvider() else {
            let message = "Accept tap declining to consume keyCode=\(keyEvent.keyCode): "
                + "coordinator reports no visible suggestion"
            LingroveLogger.app.debug("\(message)")
            return .passThrough
        }

        guard let onEvent else {
            LingroveLogger.app.debug("Accept tap declining to consume keyCode=\(keyEvent.keyCode): no event handler")
            return .passThrough
        }

        let capturedEvent = CapturedInputEvent(
            kind: kind,
            keyCode: keyEvent.keyCode,
            characters: "",
            flags: keyEvent.flags,
            isAutorepeat: keyEvent.isAutorepeat
        )
        guard onEvent(capturedEvent) else {
            LingroveLogger.app.debug(
                "Accept tap passed keyCode=\(keyEvent.keyCode) through because coordinator declined acceptance"
            )
            return .passThrough
        }

        let eventModifiers = ShortcutModifierMask(eventFlags: keyEvent.flags)
        LingroveLogger.app.debug(
            "Accept tap consumed keyCode=\(keyEvent.keyCode) modifiers=\(eventModifiers.rawValue)"
        )
        return .consume
    }

    private func routeObserverKeyDown(_ keyEvent: InputMonitorKeyEvent, mayRecognizeAcceptance: Bool = true) -> CapturedInputEvent? {
        // While an emoji capture is open, the accept key must reach the observer's `onEvent` so the
        // emoji controller can commit on it. The emoji commit fires from the ordered observation pass
        // (the accept tap only swallows the key afterward), so suppressing the accept key here — which
        // we do whenever a ghost suggestion is concurrently visible (`isAcceptTapOwningAcceptKeys`) —
        // would freeze the emoji controller out of its own commit key and route Tab to the suggestion
        // accept path instead. Excluding capture from acceptance recognition keeps the emoji picker's
        // "first look at every keystroke" invariant intact even when a suggestion overlay is showing.
        let recognizesAcceptance = mayRecognizeAcceptance && isAcceptTapOwningAcceptKeys && !captureInterceptionActive
        let capturedEvent = classify(keyEvent: keyEvent, recognizesAcceptance: recognizesAcceptance)
        // Trace-level so it is free at the default floor; under `-lingrove-debug` every observed key
        // lands in the JSONL stream, which is how a "why did the ghost vanish" report gets answered.
        // Metadata only: this monitor sees every field, secure ones included, and the secure-field
        // gate runs later in the coordinator, so neither the characters nor a printable key's code
        // (which names the character just as well) may reach the on-disk log.
        if LingroveLogger.app.logLevel <= .trace {
            var metadata: Logger.Metadata = [
                "stage": .string("input-event"),
                "kind": .string(capturedEvent.kind.rawValue),
                "char_count": .stringConvertible(capturedEvent.characters.count)
            ]
            if capturedEvent.kind != .textMutation {
                metadata["key_code"] = .stringConvertible(capturedEvent.keyCode)
            }
            LingroveLogger.app.trace("Observed key", metadata: metadata)
        }
        guard !capturedEvent.kind.isAcceptance else {
            // Acceptance is handled by the active default tap, because only that callback can
            // make insertion and "consume the original key" one atomic decision. If the active
            // tap is absent, printable accept bindings are classified as ordinary typing.
            return nil
        }

        _ = onEvent?(capturedEvent)
        return capturedEvent
    }

    private func keyCode(from event: CGEvent) -> CGKeyCode {
        CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    }

    /// Reduces a key snapshot into the smaller event categories the suggestion coordinator understands.
    private func classify(keyEvent: InputMonitorKeyEvent, recognizesAcceptance: Bool = true) -> CapturedInputEvent {
        let keyCode = keyEvent.keyCode
        let flags = keyEvent.flags

        // Normalize to just the four bits we care about — `CGEventFlags` also carries caps lock,
        // numeric pad, secondary fn, and device flags that must not influence shortcut equality.
        if recognizesAcceptance, let kind = acceptanceKind(for: keyEvent) {
            return CapturedInputEvent(kind: kind, keyCode: keyCode, characters: "", flags: flags)
        }

        // We classify events by behavior instead of raw key codes alone.
        // That keeps the prediction layer coupled to "what happened" rather than "which key fired."
        if [123, 124, 125, 126].contains(keyCode) {
            return CapturedInputEvent(kind: .navigation, keyCode: keyCode, characters: "", flags: flags)
        }

        // Backspace (51) and forward-delete (117) mutate field content. Return (36) and Keypad
        // Enter (76) intentionally fall through to the dismissal block below alongside Escape.
        // Enter often acts as navigation rather than text input (Find Bar next-match, single-line
        // form submit, chat send), and even in multi-line fields the next character typed will
        // schedule a fresh prediction anyway — regenerating on Enter itself just masks the user's
        // post-Enter action with a stale overlay.
        if [51, 117].contains(keyCode) {
            return CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: "", flags: flags)
        }

        // 53 = Escape, 36 = Return, 76 = Keypad Enter.
        if [53, 36, 76].contains(keyCode) {
            return CapturedInputEvent(kind: .dismissal, keyCode: keyCode, characters: "", flags: flags)
        }

        if flags.contains(.maskCommand) {
            let mutationShortcutKeyCodes: Set<CGKeyCode> = [0, 6, 7, 9]
            let kind: CapturedInputEvent.Kind = mutationShortcutKeyCodes.contains(keyCode) ? .shortcutMutation : .dismissal
            return CapturedInputEvent(kind: kind, keyCode: keyCode, characters: "", flags: flags)
        }

        let characters = keyEvent.characters
        if !characters.trimmingCharacters(in: .controlCharacters).isEmpty {
            return CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: characters, flags: flags)
        }

        return CapturedInputEvent(kind: .other, keyCode: keyCode, characters: characters, flags: flags)
    }

    /// True when the key matches the user's configured word-accept binding (keyCode + modifiers),
    /// using the same match the suggestion accept path uses. The emoji picker commits on this key so
    /// its commit stays consistent with accepting a suggestion word instead of hardcoding Tab/Return.
    func isWordAcceptKey(_ keyEvent: InputMonitorKeyEvent) -> Bool {
        acceptanceKind(for: keyEvent) == .acceptance
    }

    private func acceptanceKind(for keyEvent: InputMonitorKeyEvent) -> CapturedInputEvent.Kind? {
        let eventModifiers = ShortcutModifierMask(eventFlags: keyEvent.flags)

        // Read each binding once so its key code and modifiers come from the same resolution.
        let fullAccept = fullAcceptanceBindingProvider()
        let accept = acceptanceBindingProvider()

        // Full-suggestion acceptance takes priority so pressing the full-accept key doesn't
        // silently fall through to word-accept when both are assigned. The bound modifier set must
        // match exactly after normalization, so `Tab` and `Shift+Tab` remain distinct bindings.
        if keyEvent.keyCode == fullAccept.keyCode, eventModifiers == fullAccept.modifiers {
            return .fullAcceptance
        }

        if keyEvent.keyCode == accept.keyCode, eventModifiers == accept.modifiers {
            return .acceptance
        }

        return nil
    }
}

extension InputMonitor: SuggestionInputMonitoring {}
extension InputMonitor: EmojiInputIntercepting {}

private extension CapturedInputEvent.Kind {
    /// Acceptance is the one event family that must be handled by the consuming tap, not the
    /// listen-only observer. The observer can describe these keys, but it cannot stop them.
    var isAcceptance: Bool {
        self == .acceptance || self == .fullAcceptance
    }
}
