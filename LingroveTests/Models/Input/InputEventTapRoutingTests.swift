import CoreGraphics
import Testing
@testable import Lingrove

/// Pure prefilter checks protect both sides of the boundary: ordinary keys never need UI state,
/// while actual configured chords (including printable accept keys) still reach live validation.
struct InputEventTapRoutingTests {
    @Test func bindingsRequireExactNormalizedModifiers() {
        let routing = InputEventTapRouting(isMonitoring: true,
            decisionBindings: [InputKeyBinding(48), InputKeyBinding(17, [.control, .option])])
        #expect(routing.needsDecision(for: .init(keyCode: 48, flags: .maskAlphaShift), isSynthetic: false))
        #expect(!routing.needsDecision(for: .init(keyCode: 48, flags: .maskShift), isSynthetic: false))
        #expect(routing.needsDecision(for: .init(keyCode: 17, flags: [.maskControl, .maskAlternate]), isSynthetic: false))
        #expect(!routing.needsDecision(for: .init(keyCode: 17), isSynthetic: false))
    }

    @Test func inactiveAndSyntheticKeysNeverRequireAConfirmation() {
        let event = InputMonitorKeyEvent(keyCode: 0)
        let inactive = InputEventTapRouting(isModalCapture: true, decisionBindings: [InputKeyBinding(0)])
        #expect(!inactive.needsDecision(for: event, isSynthetic: false))
        let modal = InputEventTapRouting(isMonitoring: true, isModalCapture: true)
        #expect(!modal.needsDecision(for: event, isSynthetic: true))
        #expect(modal.needsDecision(for: event, isSynthetic: false))
    }

    @Test func printableAndDisabledBindingsStayDistinct() {
        let routing = InputEventTapRouting(isMonitoring: true,
            decisionBindings: [InputKeyBinding(0), InputKeyBinding(.max)], decisionKeyCodes: [53])
        #expect(routing.needsDecision(for: .init(keyCode: 0, characters: "a"), isSynthetic: false))
        #expect(!routing.needsDecision(for: .init(keyCode: .max), isSynthetic: false))
        #expect(!routing.needsDecision(for: .init(keyCode: 1, characters: "s"), isSynthetic: false))
        #expect(routing.needsDecision(for: .init(keyCode: 53, flags: .maskCommand), isSynthetic: false))
    }
}
