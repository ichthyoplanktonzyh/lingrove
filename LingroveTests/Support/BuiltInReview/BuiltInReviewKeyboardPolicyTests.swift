import LingroveNotebookEngine
import Testing
@testable import Lingrove

/// Keyboard conditions are tested as a policy table; the native component test separately
/// checks AppKit's editable text responder and exact window identity against this policy.
struct BuiltInReviewKeyboardPolicyTests {
    @Test(arguments: [1, 2, 3, 4])
    func gradingRequiresARevealedAnswer(_ digit: Int) throws {
        let action = BuiltInReviewKeyboardPolicy.action(key: .digit(digit), phase: .answer, interaction: .init(isKeyWindow: true,
            isEditingText: false, hasSheet: false, isBusy: false, canUndo: false))
        #expect(action == .rate(try #require(ReviewRating(rawValue: digit - 1))))
        #expect(BuiltInReviewKeyboardPolicy.action(key: .digit(digit), phase: .question, interaction: .init(isKeyWindow: true,
            isEditingText: false, hasSheet: false, isBusy: false, canUndo: false)) == nil)
    }

    @Test(arguments: ["editing", "sheet", "busy", "otherWindow"])
    func localInteractionFencesDisableKeys(_ fence: String) {
        for key in [BuiltInReviewKeyboardPolicy.Key.reveal, .digit(3), .undo] {
            #expect(BuiltInReviewKeyboardPolicy.action(key: key, phase: .answer, interaction: .init(
                isKeyWindow: fence != "otherWindow", isEditingText: fence == "editing", hasSheet: fence == "sheet",
                isBusy: fence == "busy", canUndo: true)) == nil)
        }
    }
}
