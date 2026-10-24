import Foundation
import Testing
@testable import Lingrove

/// Exercises the same bounded ACK runner used by the AX service, with scripted read-only evidence.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LearningSelectionAcknowledgementTests {
    private let original = NSRange(location: 2, length: 0)
    private let target = NSRange(location: 0, length: 8)

    @Test
    func delayedAXAndFocusAgreementRunsTheConfirmedWriterOnce() async throws {
        let observations = [
            evidence(rawSelection: original, focusedSelection: original),
            evidence(rawSelection: target, focusedSelection: original),
            evidence(rawSelection: target, focusedSelection: target)
        ]
        var selectionSetters = 0
        var contentWrites = 0
        var waits = 0
        let attempts = try await LearningSelectionAckTransaction.perform(
            setSelection: { selectionSetters += 1; return true },
            observe: { index in LearningSelectionAcknowledgementPolicy.assess(observations[index - 1]) },
            wait: { _ in waits += 1; await Task.yield() },
            onConfirmed: { contentWrites += 1 })

        #expect(attempts == 3)
        #expect(selectionSetters == 1)
        #expect(waits == 2)
        #expect(contentWrites == 1)
    }

    @Test
    func missingMarkedRangeRemainsUnknownWhileAwaitingTheAXReceipt() {
        let decision = LearningSelectionAcknowledgementPolicy.assess(
            evidence(inputMethodAssessment: .replacementAllowed(.unavailableWithComposition),
                rawSelection: nil, focusedSelection: original))

        #expect(decision == .pending(reason: "ax_receipt_unavailable"))
    }

    @Test(arguments: ["session", "field", "value", "source", "capability", "marked"])
    func unsafeServiceEvidenceRejectsImmediately(_ changedEvidence: String) {
        let decision: LearningSelectionAcknowledgementPolicy.Decision
        switch changedEvidence {
        case "session": decision = LearningSelectionAcknowledgementPolicy.assess(evidence(sessionMatches: false))
        case "field": decision = LearningSelectionAcknowledgementPolicy.assess(evidence(fieldMatches: false))
        case "value": decision = LearningSelectionAcknowledgementPolicy.assess(evidence(fieldValueMatches: false))
        case "source": decision = LearningSelectionAcknowledgementPolicy.assess(evidence(sourceMatches: false))
        case "capability": decision = LearningSelectionAcknowledgementPolicy.assess(evidence(capabilityIsSupported: false))
        default: decision = LearningSelectionAcknowledgementPolicy.assess(evidence(hasHostMarkedText: true))
        }

        #expect({ if case .rejected = decision { true } else { false } }())
    }

    @Test
    func focusSelectionChangeMayChangeSignatureWithoutChangingTheSavedText() {
        let source = "A short source sentence."
        let valueLength = (source as NSString).length
        let original = NSRange(location: valueLength, length: 0)
        let target = NSRange(location: 0, length: valueLength)
        let caretContext = LingroveTestFixtures.focusedInputSnapshot(
            precedingText: source, selection: original, documentLength: valueLength)
        let selectedContext = LingroveTestFixtures.focusedInputSnapshot(
            precedingText: source, selection: target, documentLength: valueLength)

        #expect(caretContext.sessionIdentity == selectedContext.sessionIdentity)
        #expect(caretContext.contentSignature != selectedContext.contentSignature)
        #expect(LearningSelectionAcknowledgementPolicy.assess(evidence(
            fieldValueMatches: true, sourceMatches: true, selectionRepresentationMatches: true,
            replacementSafetyMatches: true, rawSelection: target, focusedSelection: target,
            originalSelection: original, targetSelection: target)) == .confirmed)
    }

    @Test
    func arbitrarySelectionDriftRejectsWithoutCallingTheWriter() async {
        let drifted = evidence(rawSelection: NSRange(location: 12, length: 1), focusedSelection: original)
        let decision = LearningSelectionAcknowledgementPolicy.assess(drifted)
        var selectionSetters = 0
        var contentWrites = 0

        do {
            _ = try await LearningSelectionAckTransaction.perform(
                setSelection: { selectionSetters += 1; return true },
                observe: { _ in decision },
                wait: { _ in await Task.yield() },
                onConfirmed: { contentWrites += 1 })
            Issue.record("Selection drift must reject before the content writer.")
        } catch {
            #expect(error as? LearningSelectionAckTransaction.Failure == .rejected("ax_selection_drift"))
        }

        #expect(selectionSetters == 1)
        #expect(contentWrites == 0)
    }

    @Test
    func positiveMarkedRangeRejectsWithoutCallingTheWriter() async {
        let assessment = LearningInputMethodPolicy.assess(
            markedRange: NSRange(location: 3, length: 2), isComposingInputMethod: true)
        let decision = LearningSelectionAcknowledgementPolicy.assess(
            evidence(inputMethodAssessment: assessment, rawSelection: original, focusedSelection: original))
        var contentWrites = 0

        do {
            _ = try await LearningSelectionAckTransaction.perform(
                setSelection: { true }, observe: { _ in decision },
                wait: { _ in await Task.yield() }, onConfirmed: { contentWrites += 1 })
            Issue.record("Active marked text must reject before the content writer.")
        } catch {
            #expect(error as? LearningSelectionAckTransaction.Failure == .rejected("positive_marked_range"))
        }

        #expect(contentWrites == 0)
    }

    @Test
    func timeoutNeverCallsTheContentWriter() async {
        var selectionSetters = 0
        var observations = 0
        var contentWrites = 0
        do {
            _ = try await LearningSelectionAckTransaction.perform(
                setSelection: { selectionSetters += 1; return true },
                observe: { _ in
                    observations += 1
                    return LearningSelectionAcknowledgementPolicy.assess(
                        evidence(rawSelection: original, focusedSelection: original))
                },
                wait: { _ in await Task.yield() },
                onConfirmed: { contentWrites += 1 })
            Issue.record("The bounded ACK must time out while the host remains at the saved caret.")
        } catch {
            #expect(error as? LearningSelectionAckTransaction.Failure == .timedOut)
        }

        #expect(selectionSetters == 1)
        #expect(observations == LearningSelectionAckTransaction.maximumAttempts)
        #expect(contentWrites == 0)
    }

    @Test
    func cancellationDuringTheACKWaitNeverCallsTheContentWriter() async {
        var selectionSetters = 0
        var waitStarted = false
        var contentWrites = 0
        let transaction = Task { @MainActor in
            try await LearningSelectionAckTransaction.perform(
                setSelection: { selectionSetters += 1; return true },
                observe: { _ in .pending(reason: "awaiting_target_selection") },
                wait: { _ in
                    waitStarted = true
                    try await Task.sleep(for: .seconds(30))
                },
                onConfirmed: { contentWrites += 1 })
        }
        for _ in 0..<100 where !waitStarted { await Task.yield() }
        #expect(waitStarted)
        transaction.cancel()
        do {
            _ = try await transaction.value
            Issue.record("Cancellation must escape the ACK loop before content dispatch.")
        } catch is CancellationError {
            // Expected: the exact editor selection was never acknowledged.
        } catch {
            Issue.record("Expected cancellation, received \(error).")
        }

        #expect(selectionSetters == 1)
        #expect(contentWrites == 0)
    }

    private func evidence(
        sessionMatches: Bool = true,
        fieldMatches: Bool = true,
        hostIsFrontmost: Bool = true,
        capabilityIsSupported: Bool = true,
        isSecure: Bool = false,
        isIntegratedTerminal: Bool = false,
        hasHostMarkedText: Bool = false,
        inputMethodAssessment: LearningInputMethodPolicy.Assessment = .replacementAllowed(.unavailableWithComposition),
        fieldValueMatches: Bool? = true,
        sourceMatches: Bool? = true,
        selectionRepresentationMatches: Bool? = true,
        replacementSafetyMatches: Bool? = true,
        rawSelection: NSRange? = NSRange(location: 2, length: 0),
        focusedSelection: NSRange = NSRange(location: 2, length: 0),
        originalSelection: NSRange? = nil,
        targetSelection: NSRange? = nil
    ) -> LearningSelectionAcknowledgementPolicy.Evidence {
        .init(sessionMatches: sessionMatches, fieldMatches: fieldMatches,
            hostIsFrontmost: hostIsFrontmost, capabilityIsSupported: capabilityIsSupported, isSecure: isSecure,
            isIntegratedTerminal: isIntegratedTerminal, hasHostMarkedText: hasHostMarkedText,
            inputMethodAssessment: inputMethodAssessment, fieldValueMatches: fieldValueMatches,
            sourceMatches: sourceMatches, selectionRepresentationMatches: selectionRepresentationMatches,
            replacementSafetyMatches: replacementSafetyMatches, rawSelection: rawSelection,
            focusedSelection: focusedSelection, originalSelection: originalSelection ?? original,
            targetSelection: targetSelection ?? target)
    }
}
