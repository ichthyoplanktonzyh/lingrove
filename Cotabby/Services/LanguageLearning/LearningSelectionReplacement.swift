import AppKit
import ApplicationServices
import Logging

/// Captures the exact editor value and selection in memory after an expression-preview request.
/// AX may omit its marked-range attribute even when a composition-capable input source is selected,
/// so the capture records that evidence as unknown rather than treating it as active preedit. The
/// user's Replace click or configured chord confirms this saved preview; this service owns the
/// final freshness checks and single scoped write. AX handles retain their CF object and never enter
/// a model request, while `LearningTextScopePolicy` keeps the source bounded.
@MainActor
struct LearningSelectionCapture {
    let element: AXUIElement
    let context: FocusedInputSnapshot
    let value: String
    let range: NSRange
    let source: String
    var usesTextMarkers: Bool = false
    var editorSelection: NSRange?
    /// Optional explanation for a capture that cannot offer replacement. Missing AX evidence under
    /// a composition-capable input source alone does not set this; the coordinator presents a
    /// separate fallback for other unsupported capture shapes.
    var replacementUnavailableReason: String?
    /// Kept with the capture so revalidation detects changes in the host's marked-range evidence;
    /// an absent range remains unknown and does not prove that input-method composition committed.
    var inputMethodAssessment: LearningInputMethodPolicy.Assessment
    var originalSelection: NSRange { editorSelection ?? context.documentSelection }
    var supportsReplacement: Bool {
        replacementUnavailableReason == nil && inputMethodAssessment.permitsReplacement &&
            (!usesTextMarkers || originalSelection.length > 0)
    }

    /// Compares write capability, not the exact AX/TIS report. Two permitted assessments remain
    /// compatible when the selected input source's state changes from an unknown marked range to an
    /// explicit empty one; a missing range remains unknown and never means composition committed.
    /// Preview freshness still requires exact field, value, source and selection checks.
    func hasSameReplacementSafety(as other: LearningSelectionCapture) -> Bool {
        let assessmentsRemainWritable = inputMethodAssessment.permitsReplacement &&
            other.inputMethodAssessment.permitsReplacement
        let assessmentsRemainEquallyRestricted = inputMethodAssessment == other.inputMethodAssessment
        return (assessmentsRemainWritable || assessmentsRemainEquallyRestricted) &&
            replacementUnavailableReason == other.replacementUnavailableReason &&
            usesTextMarkers == other.usesTextMarkers &&
            supportsReplacement == other.supportsReplacement
    }
}

/// Narrow AX transaction boundary. Native fields use selected-text writes; web fields use a
/// verified Paste command. Neither path overwrites a whole field or retries an uncertain edit. Verification
/// distinguishes a successful AX call from a successful editor edit; uncertain edits are not retried.
@MainActor
final class LearningSelectionReplacement: LearningSelectionReplacing {
    private struct AcknowledgedSelectionObservation {
        let decision: LearningSelectionAcknowledgementPolicy.Decision
        let capture: LearningSelectionCapture?
    }

    private let focus: FocusTrackingModel
    private let inputSource: KeyboardInputSourceMonitor
    private let inserter: SuggestionInserter

    init(focus: FocusTrackingModel, inputSource: KeyboardInputSourceMonitor, inserter: SuggestionInserter) {
        self.inserter = inserter
        self.focus = focus
        self.inputSource = inputSource
    }

    func capture() throws -> LearningSelectionCapture {
        focus.refreshNow()
        guard LearningCapturePolicy.permitsExplicitCapture(focus.snapshot.capability), let context = focus.snapshot.context,
              !context.isSecure, !context.isIntegratedTerminal,
              let element = AXHelper.focusedElement(forApplicationPID: context.processIdentifier),
              AXHelper.elementIdentifier(for: element, bundleIdentifier: context.bundleIdentifier) == context.elementIdentifier,
              let receipt = AXHelper.exactEditableTextSelection(on: element),
              receipt.range == context.documentSelection else {
            throw LearningFailure.message(String(localized: """
            This field or selection cannot be verified. Select the committed source text again; the original text was kept.
            """,
                table: "Learning", comment: """
                Error shown when Accessibility cannot verify the field, selection, or committed source text for a translation preview.
                """))
        }
        guard !context.hasHostMarkedText else {
            throw LearningFailure.message(LearningInputMethodPolicy.markedTextConfirmationMessage)
        }
        let value = receipt.value
        let range = receipt.range
        let marked = AXHelper.rangeValue(for: HostMarkedTextPolicy.markedRangeAttribute as CFString, on: element)
        let inputMethodAssessment = LearningInputMethodPolicy.assess(
            markedRange: marked,
            isComposingInputMethod: inputSource.isComposingIMEActive
        )
        if let reason = inputMethodAssessment.previewRejectionReason {
            throw LearningFailure.message(reason)
        }
        let replacementRange = try LearningTextScopePolicy.conversionRange(value: value, selection: range)
        let source = try LearningTextScopePolicy.text(value: value, range: replacementRange)
        guard receipt.usesTextMarkers || range.length == 0 ||
                AXHelper.stringValue(for: kAXSelectedTextAttribute as CFString, on: element) == source else {
            throw LearningFailure.message(String(localized: "The selected text does not match the field range; the original text was kept.",
                table: "Learning", comment: "Error shown when the selected text differs from the verified range in the editor."))
        }
        return LearningSelectionCapture(element: element, context: context, value: value, range: replacementRange, source: source,
            usesTextMarkers: receipt.usesTextMarkers, editorSelection: range,
            replacementUnavailableReason: inputMethodAssessment.replacementUnavailableReason,
            inputMethodAssessment: inputMethodAssessment)
    }

    func isCurrent(_ saved: LearningSelectionCapture) -> Bool {
        guard let current = try? capture() else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == saved.context.processIdentifier &&
            current.context.sessionIdentity == saved.context.sessionIdentity &&
            CFEqual(current.element, saved.element) && current.value.utf16.elementsEqual(saved.value.utf16) &&
            current.range == saved.range &&
            current.originalSelection == saved.originalSelection &&
            current.hasSameReplacementSafety(as: saved)
    }

    func replace(_ saved: LearningSelectionCapture, with english: String) async throws {
        let traceID = LearningRequestTrace.requestID ?? "untracked"
        var finalResult = "failed"
        defer {
            let result = Task.isCancelled ? "cancelled" : finalResult
            logReplacement(result == "verified" ? .info : .warning, traceID: traceID,
                status: "result", details: ["result": result])
        }

        try Task.checkCancellation()
        guard saved.supportsReplacement else {
            logReplacement(.warning, traceID: traceID, status: "preflight_rejected", details: ["reason": "unsupported_capture"])
            throw LearningFailure.message(saved.replacementUnavailableReason ??
                String(localized: """
                This editor only provides text markers. Copy the current sentence translation, or select the source manually and \
                preview it again.
                """,
                    table: "Learning", comment: """
                    Copy-only recovery guidance when the editor does not expose a safe text-selection replacement action.
                    """))
        }
        guard isCurrent(saved) else {
            logReplacement(.warning, traceID: traceID, status: "preflight_rejected", details: ["reason": "saved_capture_changed"])
            throw LearningFailure.message(String(localized: """
            The text, selection, or conversation changed. The previous translation is no longer valid.
            """,
                table: "Learning", comment: "Error shown when the saved source text or host conversation changes before replacement."))
        }
        let expected = (saved.value as NSString).replacingCharacters(in: saved.range, with: english)
        let isWeb = saved.context.isWebContentField || saved.usesTextMarkers
        if saved.originalSelection.length == 0 {
            try await prepareSelectionAndDispatch(saved, english: english, isWeb: isWeb, traceID: traceID)
        } else {
            try dispatchContent(saved, english: english, isWeb: isWeb, traceID: traceID)
        }
        // Editors publish AX state asynchronously. Never roll back an unverified value: the user
        // may already have typed, and an automatic restoration could overwrite their new content.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(60))
            focus.refreshNow()
            let sameSession = focus.snapshot.context?.sessionIdentity == saved.context.sessionIdentity
            if LearningReplacementVerificationPolicy.accepts(expectedValue: expected,
                actualValue: AXHelper.exactEditableTextSelection(on: saved.element)?.value,
                isWebContentField: isWeb, sameSession: sameSession) {
                finalResult = "verified"
                return
            }
            if isWeb, !sameSession { break }
        }
        throw LearningFailure.message(String(localized: """
        Could not verify the replacement. Check the editor. The card keeps copy actions for the source and translation to avoid \
        another overwrite.
        """,
            table: "Learning", comment: "Recovery guidance when Accessibility cannot confirm whether the editor applied the replacement."))
    }

    private func prepareSelectionAndDispatch(
        _ saved: LearningSelectionCapture, english: String, isWeb: Bool, traceID: String
    ) async throws {
        try verifyCaretPreselectionSafety(saved, traceID: traceID)
        var acknowledgedCapture: LearningSelectionCapture?
        do {
            let attempts = try await LearningSelectionAckTransaction.perform(
                setSelection: { self.setTargetSelection(saved, traceID: traceID) },
                observe: { _ in
                    let observation = self.observeSelectionAcknowledgement(saved)
                    acknowledgedCapture = observation.capture
                    return observation.decision
                },
                onAttempt: { attempt, decision in
                    self.logAcknowledgementAttempt(decision, attempt: attempt, traceID: traceID)
                },
                onConfirmed: {
                    try self.dispatchAcknowledgedContent(acknowledgedCapture,
                        english: english, isWeb: isWeb, traceID: traceID)
                })
            logReplacement(.info, traceID: traceID, status: "selection_ack_confirmed",
                details: ["attempts": String(attempts)])
        } catch let failure as LearningSelectionAckTransaction.Failure {
            logAcknowledgementFailure(failure, traceID: traceID)
            throw acknowledgementFailure(failure)
        }
    }

    private func verifyCaretPreselectionSafety(_ saved: LearningSelectionCapture, traceID: String) throws {
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(saved.element, kAXSelectedTextRangeAttribute as CFString, &writable) == .success,
              writable.boolValue else {
            logReplacement(.warning, traceID: traceID, status: "preflight_rejected", details: ["reason": "range_not_writable"])
            throw LearningFailure.message(String(localized:
                "Could not safely select the current sentence. Copy the translation or select the source manually.",
                table: "Learning", comment: "Recovery guidance when the current sentence cannot be selected safely for replacement."))
        }
        guard isCurrent(saved) else {
            logReplacement(.warning, traceID: traceID, status: "preflight_rejected", details: ["reason": "saved_capture_changed"])
            throw LearningFailure.message(String(localized:
                "The text, selection, or conversation changed. The previous translation is no longer valid.",
                table: "Learning", comment: "Error shown when the saved source text or host conversation changes before replacement."))
        }
    }

    private func setTargetSelection(_ saved: LearningSelectionCapture, traceID: String) -> Bool {
        var range = CFRange(location: saved.range.location, length: saved.range.length)
        guard let axRange = AXValueCreate(.cfRange, &range) else {
            logReplacement(.warning, traceID: traceID, status: "preselect_dispatch",
                details: ["dispatched": "false", "phase": "range_value_unavailable"])
            return false
        }
        let result = AXUIElementSetAttributeValue(saved.element, kAXSelectedTextRangeAttribute as CFString, axRange)
        let dispatched = result == .success
        logReplacement(dispatched ? .info : .warning, traceID: traceID, status: "preselect_dispatch",
            details: ["dispatched": String(dispatched)])
        return dispatched
    }

    private func dispatchAcknowledgedContent(
        _ capture: LearningSelectionCapture?, english: String, isWeb: Bool, traceID: String
    ) throws {
        guard let capture else {
            throw LearningFailure.message(String(localized:
                "Could not verify the sentence selection. No text was replaced; select the source manually or copy the translation.",
                table: "Learning", comment: """
                Error shown when the selected sentence does not match the saved source; replacement has not run.
                """))
        }
        try dispatchContent(capture, english: english, isWeb: isWeb, traceID: traceID)
    }

    private func logAcknowledgementFailure(_ failure: LearningSelectionAckTransaction.Failure, traceID: String) {
        switch failure {
        case .selectionSetterFailed:
            logReplacement(.warning, traceID: traceID, status: "selection_ack_rejected",
                details: ["reason": "selection_setter_failed"])
        case let .rejected(reason):
            logReplacement(.warning, traceID: traceID, status: "selection_ack_rejected", details: ["reason": reason])
        case .timedOut:
            logReplacement(.warning, traceID: traceID, status: "selection_ack_timeout",
                details: ["attempts": String(LearningSelectionAckTransaction.maximumAttempts)])
        }
    }

    private func observeSelectionAcknowledgement(_ saved: LearningSelectionCapture) -> AcknowledgedSelectionObservation {
        focus.refreshNow()
        let snapshot = focus.snapshot
        guard let context = snapshot.context else {
            return .init(decision: .rejected(reason: "focus_unavailable"), capture: nil)
        }
        let focusedElement = AXHelper.focusedElement(forApplicationPID: context.processIdentifier)
        let fieldMatches = AXHelper.elementIdentifier(for: focusedElement ?? saved.element,
            bundleIdentifier: context.bundleIdentifier) == context.elementIdentifier &&
            focusedElement.map { CFEqual($0, saved.element) } == true
        let marked = AXHelper.rangeValue(for: HostMarkedTextPolicy.markedRangeAttribute as CFString, on: saved.element)
        let assessment = LearningInputMethodPolicy.assess(
            markedRange: marked, isComposingInputMethod: inputSource.isComposingIMEActive)
        let receipt = AXHelper.exactEditableTextSelection(on: saved.element)
        let fieldValueMatches: Bool? = if let receipt {
            receipt.value.utf16.elementsEqual(saved.value.utf16)
        } else {
            AXHelper.stringValue(for: kAXValueAttribute as CFString, on: saved.element)
                .map { $0.utf16.elementsEqual(saved.value.utf16) }
        }
        let sourceMatches: Bool? = if let receipt {
            (try? LearningTextScopePolicy.text(value: receipt.value, range: saved.range)) == saved.source
        } else { nil }
        let representationMatches = receipt.map { $0.usesTextMarkers == saved.usesTextMarkers }
        let replacementSafetyMatches: Bool?
        if let receipt, let source = try? LearningTextScopePolicy.text(value: receipt.value, range: saved.range) {
            let live = LearningSelectionCapture(element: focusedElement ?? saved.element, context: context,
                value: receipt.value, range: saved.range, source: source, usesTextMarkers: receipt.usesTextMarkers,
                editorSelection: receipt.range, replacementUnavailableReason: assessment.replacementUnavailableReason,
                inputMethodAssessment: assessment)
            replacementSafetyMatches = saved.hasSameReplacementSafety(as: live)
        } else {
            replacementSafetyMatches = nil
        }

        let evidence = LearningSelectionAcknowledgementPolicy.Evidence(
            sessionMatches: context.sessionIdentity == saved.context.sessionIdentity,
            fieldMatches: fieldMatches,
            hostIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == saved.context.processIdentifier,
            capabilityIsSupported: LearningCapturePolicy.permitsExplicitCapture(snapshot.capability),
            isSecure: context.isSecure,
            isIntegratedTerminal: context.isIntegratedTerminal,
            hasHostMarkedText: context.hasHostMarkedText,
            inputMethodAssessment: assessment,
            fieldValueMatches: fieldValueMatches,
            sourceMatches: sourceMatches,
            selectionRepresentationMatches: representationMatches,
            replacementSafetyMatches: replacementSafetyMatches,
            rawSelection: receipt?.range,
            focusedSelection: context.documentSelection,
            originalSelection: saved.originalSelection,
            targetSelection: saved.range)
        let decision = LearningSelectionAcknowledgementPolicy.assess(evidence)
        guard decision == .confirmed else { return .init(decision: decision, capture: nil) }
        guard let receipt, let focusedElement else {
            return .init(decision: .rejected(reason: "acknowledgement_evidence_incomplete"), capture: nil)
        }
        guard let range = try? LearningTextScopePolicy.conversionRange(value: receipt.value, selection: receipt.range),
              range == saved.range,
              let source = try? LearningTextScopePolicy.text(value: receipt.value, range: range), source == saved.source else {
            return .init(decision: .rejected(reason: "confirmed_source_mismatch"), capture: nil)
        }
        guard receipt.usesTextMarkers || receipt.range.length == 0 ||
                AXHelper.stringValue(for: kAXSelectedTextAttribute as CFString, on: saved.element) == source else {
            return .init(decision: .rejected(reason: "selected_text_mismatch"), capture: nil)
        }
        let selected = LearningSelectionCapture(element: focusedElement, context: context, value: receipt.value,
            range: range, source: source, usesTextMarkers: receipt.usesTextMarkers, editorSelection: receipt.range,
            replacementUnavailableReason: assessment.replacementUnavailableReason, inputMethodAssessment: assessment)
        guard matchesAcknowledgedCapture(selected, saved: saved) else {
            return .init(decision: .rejected(reason: "confirmed_capture_mismatch"), capture: nil)
        }
        return .init(decision: .confirmed, capture: selected)
    }

    private func matchesAcknowledgedCapture(_ selected: LearningSelectionCapture, saved: LearningSelectionCapture) -> Bool {
        selected.context.sessionIdentity == saved.context.sessionIdentity &&
            selected.context.elementIdentifier == saved.context.elementIdentifier &&
            CFEqual(selected.element, saved.element) && selected.value.utf16.elementsEqual(saved.value.utf16) &&
            selected.range == saved.range && selected.source == saved.source &&
            selected.originalSelection == saved.range && selected.supportsReplacement &&
            selected.hasSameReplacementSafety(as: saved)
    }

    private func dispatchContent(
        _ transaction: LearningSelectionCapture, english: String, isWeb: Bool, traceID: String
    ) throws {
        if isWeb {
            var validationPhase = "not_invoked"
            var validationReason = "none"
            var pastePhase = "no_dispatch_detail"
            // Scoped Paste reports dispatch only. Its callback validates the exact transaction at
            // the menu-action boundary; neither a false validation nor an uncertain press is retried.
            let dispatched = inserter.pasteSelectedText(english, inApplicationPID: transaction.context.processIdentifier,
                onDispatchPhase: { pastePhase = $0 },
                validateSelection: {
                    validationPhase = "before_paste_action"
                    guard !Task.isCancelled else { validationReason = "cancelled"; return false }
                    guard self.isCurrent(transaction) else { validationReason = "saved_capture_changed"; return false }
                    validationPhase = "validated"
                    return true
                })
            logReplacement(dispatched ? .info : .warning, traceID: traceID, status: "content_dispatch", details: [
                "route": "paste", "dispatched": String(dispatched), "phase": pastePhase,
                "validation": validationPhase, "validation_reason": validationReason
            ])
            if validationReason == "cancelled" { throw CancellationError() }
            if validationReason != "none" {
                throw LearningFailure.message(String(localized: "The selection changed; the original text was kept.",
                    table: "Learning", comment: "Error shown when the selection changes just before a confirmed replacement."))
            }
        } else {
            var writable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(transaction.element, kAXSelectedTextAttribute as CFString, &writable) == .success,
                  writable.boolValue else {
                logReplacement(.warning, traceID: traceID, status: "content_dispatch",
                    details: ["route": "native", "dispatched": "false", "phase": "attribute_not_writable"])
                throw LearningFailure.message(String(localized: """
                This field does not support safe selection replacement. Copy and paste the translation manually; the original text was \
                kept.
                """,
                    table: "Learning", comment: """
                    Recovery guidance when the host field does not allow safe replacement of the selected source.
                    """))
            }
            guard isCurrent(transaction) else {
                logReplacement(.warning, traceID: traceID, status: "content_dispatch",
                    details: ["route": "native", "dispatched": "false", "phase": "saved_capture_changed"])
                throw LearningFailure.message(String(localized: "The selection changed; the original text was kept.",
                    table: "Learning", comment: "Error shown when the selection changes just before a confirmed replacement."))
            }
            try Task.checkCancellation()
            let result = AXUIElementSetAttributeValue(transaction.element, kAXSelectedTextAttribute as CFString, english as CFString)
            let dispatched = result == .success
            logReplacement(dispatched ? .info : .warning, traceID: traceID, status: "content_dispatch", details: [
                "route": "native", "dispatched": String(dispatched), "phase": "selected_text_set"
            ])
            guard dispatched else {
                throw LearningFailure.message(String(localized: """
                The editor refused the replacement. Check the source text; you can copy the translation or restore the original.
                """,
                    table: "Learning", comment: "Recovery guidance when the editor rejects a confirmed selection replacement."))
            }
        }
    }

    private func logAcknowledgementAttempt(
        _ decision: LearningSelectionAcknowledgementPolicy.Decision, attempt: Int, traceID: String
    ) {
        let fields: [String: String]
        let level: Logger.Level
        switch decision {
        case let .pending(reason):
            fields = ["attempt": String(attempt), "state": "pending", "reason": reason]
            level = .info
        case .confirmed:
            fields = ["attempt": String(attempt), "state": "confirmed", "reason": "target_agreed"]
            level = .info
        case let .rejected(reason):
            fields = ["attempt": String(attempt), "state": "rejected", "reason": reason]
            level = .warning
        }
        logReplacement(level, traceID: traceID, status: "selection_ack_attempt", details: fields)
    }

    private func acknowledgementFailure(_ failure: LearningSelectionAckTransaction.Failure) -> Error {
        switch failure {
        case .selectionSetterFailed:
            return LearningFailure.message(String(localized:
                "The editor could not select the current sentence. Select the source manually or copy the translation.",
                table: "Learning", comment: "Recovery guidance when the editor refuses to select the current sentence."))
        case let .rejected(reason) where reason == "host_marked_text" || reason == "positive_marked_range":
            return LearningFailure.message(LearningInputMethodPolicy.markedTextConfirmationMessage)
        case .timedOut:
            return LearningFailure.message(String(localized:
                "Could not verify the sentence selection. No text was replaced; select the source manually or copy the translation.",
                table: "Learning", comment: """
                Error shown when the selected sentence does not match the saved source; replacement has not run.
                """))
        case let .rejected(reason) where ["session_changed", "ax_element_changed", "field_value_changed", "field_or_value_changed",
                                          "host_not_frontmost"].contains(reason):
            return LearningFailure.message(String(localized:
                "The text, selection, or conversation changed. The previous translation is no longer valid.",
                table: "Learning", comment: "Error shown when the saved source text or host conversation changes before replacement."))
        case .rejected:
            return LearningFailure.message(String(localized:
                "Could not verify the sentence selection. No text was replaced; select the source manually or copy the translation.",
                table: "Learning", comment: """
                Error shown when the selected sentence does not match the saved source; replacement has not run.
                """))
        }
    }

    private func logReplacement(
        _ level: Logger.Level, traceID: String, status: String, details: [String: String] = [:]
    ) {
        var metadata: Logger.Metadata = ["request_id": .string(traceID), "status": .string(status)]
        details.forEach { metadata[$0.key] = .string($0.value) }
        let suffix = details.keys.sorted().map { "\($0)=\(details[$0] ?? "")" }.joined(separator: " ")
        let message = "Learning replacement trace_id=\(traceID) status=\(status) \(suffix)"
        CotabbyLogger.learning.log(level: level, "\(message)", metadata: metadata)
    }
}
