import Foundation
import Testing
@testable import Lingrove

/// Protects the preview/write boundary across input methods whose hosts expose different AX data.
@Suite
struct LearningInputMethodPolicyTests {
    @Test
    func positiveMarkedRangeRejectsPreviewUntilCandidatesAreCommitted() {
        let assessment = LearningInputMethodPolicy.assess(
            markedRange: NSRange(location: 4, length: 2),
            isComposingInputMethod: true
        )

        #expect(!assessment.permitsReplacement)
        #expect(assessment.replacementUnavailableReason == nil)
        #expect(assessment.previewRejectionReason?.contains("candidate") == true)
    }

    @Test
    func explicitZeroMarkedRangePreservesWritableBehaviorEvenForComposingInputMethod() {
        let assessment = LearningInputMethodPolicy.assess(
            markedRange: NSRange(location: NSNotFound, length: 0),
            isComposingInputMethod: true
        )

        #expect(assessment == .replacementAllowed(.explicitlyEmpty))
        #expect(assessment.permitsReplacement)
    }

    @Test(arguments: [false, true])
    func negativeMarkedRangeStaysCopyOnlyRegardlessOfInputSource(_ isComposingInputMethod: Bool) {
        let assessment = LearningInputMethodPolicy.assess(
            markedRange: NSRange(location: 4, length: -1),
            isComposingInputMethod: isComposingInputMethod
        )

        #expect(assessment == .copyOnly(reason: LearningInputMethodPolicy.unavailableMarkedRangeReason))
        #expect(!assessment.permitsReplacement)
        #expect(assessment.replacementUnavailableReason == LearningInputMethodPolicy.unavailableMarkedRangeReason)
    }

    @Test
    func missingRangeUnderCompositionCapableInputMethodStaysUnknownAndAllowsConfirmedReplacement() {
        let assessment = LearningInputMethodPolicy.assess(
            markedRange: nil,
            isComposingInputMethod: true
        )

        #expect(assessment == .replacementAllowed(.unavailableWithComposition))
        #expect(assessment.permitsReplacement)
        #expect(assessment.replacementUnavailableReason == nil)
    }

    @Test
    func missingRangeWithDirectLayoutKeepsExistingWritableBehavior() {
        let assessment = LearningInputMethodPolicy.assess(
            markedRange: nil,
            isComposingInputMethod: false
        )

        #expect(assessment == .replacementAllowed(.unavailableWithoutComposition))
        #expect(assessment.permitsReplacement)
    }
}
