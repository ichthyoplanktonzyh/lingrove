import AppKit
import ApplicationServices
import Logging

/// App-owned adapter around the existing verified editor transaction. The capture itself lives
/// only in the coordinator's current session. Reading a retained AX element while our panel is
/// key is allowed; writing waits until the host is focused and a fresh capture agrees exactly.
@MainActor
final class ExpressionAssistEditor: ExpressionAssistEditing {
    private let focus: any SuggestionFocusProviding
    private let replacement: LearningSelectionReplacement
    private let inputOwnsKeyboard: () -> Bool

    init(focus: any SuggestionFocusProviding, replacement: LearningSelectionReplacement,
         inputOwnsKeyboard: @escaping () -> Bool) {
        self.focus = focus
        self.replacement = replacement
        self.inputOwnsKeyboard = inputOwnsKeyboard
    }

    func capture(trigger: String?) throws -> LearningSelectionCapture {
        focus.refreshNow()
        guard let context = focus.snapshot.context else { throw changed() }
        var range = context.documentSelection
        if let trigger {
            guard range.length == 0, context.precedingText.hasSuffix(trigger), range.location >= trigger.utf16.count else {
                throw changed()
            }
            range = NSRange(location: range.location - trigger.utf16.count, length: trigger.utf16.count)
        }
        return try replacement.capture(explicitRange: range)
    }

    func isUnchanged(_ saved: LearningSelectionCapture) -> Bool {
        // Input deliberately activates Lingrove. Reading the retained host element during that
        // round trip is safe only while our input client owns the keyboard; writes still require
        // the original application and an exact, newly captured receipt in resume(_:).
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard ExpressionAssistFocusPolicy.permitsHostRead(frontmost: frontmost,
            host: saved.context.processIdentifier, inputOwner: ProcessInfo.processInfo.processIdentifier,
            inputOwnsKeyboard: inputOwnsKeyboard()) else { return reject("frontmost-changed") }
        guard let receipt = AXHelper.exactEditableTextSelection(on: saved.element) else {
            return reject("host-receipt-unavailable")
        }
        guard receipt.value.utf16.elementsEqual(saved.value.utf16) else { return reject("host-value-changed") }
        guard receipt.range == saved.originalSelection else { return reject("host-selection-changed") }
        return true
    }

    func resume(_ saved: LearningSelectionCapture) throws -> LearningSelectionCapture {
        let current = try replacement.capture(explicitRange: saved.range)
        let old = saved.context
        let new = current.context
        // FocusTracker must keep reporting the real panel focus. Only this explicit return path
        // accepts a new observation sequence; it never relaxes the global stale-result guards.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == old.processIdentifier,
              new.processIdentifier == old.processIdentifier, new.bundleIdentifier == old.bundleIdentifier,
              new.elementIdentifier == old.elementIdentifier, CFEqual(current.element, saved.element),
              new.windowTitle == old.windowTitle, new.focusedURLString == old.focusedURLString,
              new.fieldPlaceholder == old.fieldPlaceholder, current.value.utf16.elementsEqual(saved.value.utf16),
              current.originalSelection == saved.originalSelection, current.source == saved.source,
              current.hasSameReplacementSafety(as: saved) else { throw changed() }
        // Activation can briefly expose a toolbar field or advance the focus session after the
        // first usable host receipt. Run the shared write preflight read here, while the coordinator
        // can still wait and recapture. No edit has been dispatched and no write is retried.
        guard replacement.isCurrent(current) else { throw changed() }
        return current
    }

    func replace(_ saved: LearningSelectionCapture, text: String) async throws {
        try await replacement.replace(saved, with: text)
    }

    private func changed() -> LearningFailure {
        .message(String(localized: "The original field or text changed. Copy the candidate or open expression assistance again.",
            table: "Learning"))
    }

    private func reject(_ reason: String) -> Bool {
        // Content-free subreasons distinguish an input-routing failure from a stale AX receipt.
        CotabbyLogger.learning.info("Expression host verification rejected", metadata: ["reason": .string(reason)])
        return false
    }
}
