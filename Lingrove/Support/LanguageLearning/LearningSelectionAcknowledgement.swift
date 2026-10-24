import Foundation

/// Reduces the two independent selection reports involved in preselecting a caret sentence.
/// Accessibility may publish its selected range before FocusTracker polls it, but neither report
/// may move to an arbitrary range while the user-confirmed replacement is pending.
nonisolated enum LearningSelectionAcknowledgementPolicy {
    struct Evidence: Equatable, Sendable {
        let sessionMatches: Bool
        let fieldMatches: Bool
        let hostIsFrontmost: Bool
        let capabilityIsSupported: Bool
        let isSecure: Bool
        let isIntegratedTerminal: Bool
        let hasHostMarkedText: Bool
        let inputMethodAssessment: LearningInputMethodPolicy.Assessment
        let fieldValueMatches: Bool?
        let sourceMatches: Bool?
        let selectionRepresentationMatches: Bool?
        let replacementSafetyMatches: Bool?
        let rawSelection: NSRange?
        let focusedSelection: NSRange
        let originalSelection: NSRange
        let targetSelection: NSRange
    }

    enum Decision: Equatable, Sendable {
        case pending(reason: String)
        case confirmed
        case rejected(reason: String)
    }

    static func assess(_ evidence: Evidence) -> Decision {
        if let reason = identityFailure(evidence) { return .rejected(reason: reason) }
        if let reason = surfaceFailure(evidence) { return .rejected(reason: reason) }
        if let reason = inputMethodFailure(evidence) { return .rejected(reason: reason) }
        if let reason = changedContentFailure(evidence) { return .rejected(reason: reason) }
        return selectionDecision(evidence)
    }

    private static func identityFailure(_ evidence: Evidence) -> String? {
        guard evidence.sessionMatches else { return "session_changed" }
        guard evidence.fieldMatches else { return "ax_element_changed" }
        guard evidence.hostIsFrontmost else { return "host_not_frontmost" }
        return nil
    }

    private static func surfaceFailure(_ evidence: Evidence) -> String? {
        guard evidence.capabilityIsSupported else { return "unsupported_field" }
        guard !evidence.isSecure else { return "secure_field" }
        guard !evidence.isIntegratedTerminal else { return "integrated_terminal" }
        guard !evidence.hasHostMarkedText else { return "host_marked_text" }
        return nil
    }

    private static func inputMethodFailure(_ evidence: Evidence) -> String? {
        guard !evidence.inputMethodAssessment.permitsReplacement else { return nil }
        return evidence.inputMethodAssessment.previewRejectionReason == nil
            ? "invalid_marked_range" : "positive_marked_range"
    }

    private static func changedContentFailure(_ evidence: Evidence) -> String? {
        if evidence.fieldValueMatches == false { return "field_value_changed" }
        if evidence.sourceMatches == false { return "source_changed" }
        if evidence.selectionRepresentationMatches == false { return "selection_representation_changed" }
        if evidence.replacementSafetyMatches == false { return "replacement_safety_changed" }
        return nil
    }

    private static func selectionDecision(_ evidence: Evidence) -> Decision {
        let expectedSelections = [evidence.originalSelection, evidence.targetSelection]
        guard expectedSelections.contains(evidence.focusedSelection) else {
            return .rejected(reason: "focus_selection_drift")
        }
        guard let rawSelection = evidence.rawSelection else { return .pending(reason: "ax_receipt_unavailable") }
        guard expectedSelections.contains(rawSelection) else { return .rejected(reason: "ax_selection_drift") }
        guard evidence.fieldValueMatches == true, evidence.sourceMatches == true,
              evidence.selectionRepresentationMatches == true, evidence.replacementSafetyMatches == true else {
            return .rejected(reason: "acknowledgement_evidence_incomplete")
        }

        if rawSelection == evidence.targetSelection, evidence.focusedSelection == evidence.targetSelection { return .confirmed }
        if rawSelection == evidence.targetSelection { return .pending(reason: "focus_tracker_lag") }
        if evidence.focusedSelection == evidence.targetSelection { return .pending(reason: "ax_selection_lag") }
        return .pending(reason: "awaiting_target_selection")
    }
}

/// Owns the one-selection-setter ACK sequence for caret-based replacement. The injected closures
/// keep its polling bound deterministic in tests; the content dispatcher runs only after the host
/// and FocusTracker agree on the exact requested range.
@MainActor
enum LearningSelectionAckTransaction {
    enum Failure: Error, Equatable {
        case selectionSetterFailed
        case rejected(String)
        case timedOut
    }

    static let maximumAttempts = 7
    static let pollInterval = Duration.milliseconds(45)

    @discardableResult
    static func perform(
        setSelection: @MainActor () -> Bool,
        observe: @MainActor (Int) throws -> LearningSelectionAcknowledgementPolicy.Decision,
        wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onAttempt: @MainActor (Int, LearningSelectionAcknowledgementPolicy.Decision) -> Void = { _, _ in },
        onConfirmed: @MainActor () throws -> Void
    ) async throws -> Int {
        try Task.checkCancellation()
        guard setSelection() else { throw Failure.selectionSetterFailed }

        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            let decision = try observe(attempt)
            onAttempt(attempt, decision)
            switch decision {
            case .confirmed:
                try Task.checkCancellation()
                try onConfirmed()
                return attempt
            case let .rejected(reason):
                throw Failure.rejected(reason)
            case .pending:
                if attempt < maximumAttempts { try await wait(pollInterval) }
            }
        }
        throw Failure.timedOut
    }
}
