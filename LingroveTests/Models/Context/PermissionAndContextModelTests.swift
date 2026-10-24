import XCTest
@testable import Lingrove

/// Pins the permission metadata the onboarding, menu, and Settings permission rows render. The raw
/// values double as System Settings deep-link anchors, so they are a compatibility contract.
final class LingrovePermissionKindTests: XCTestCase {

    func test_allCases_listsPermissionsInOnboardingOrderWithPrivacyAnchorRawValues() {
        XCTAssertEqual(LingrovePermissionKind.allCases, [.accessibility, .inputMonitoring, .screenRecording])
        XCTAssertEqual(LingrovePermissionKind.accessibility.rawValue, "Privacy_Accessibility")
        XCTAssertEqual(LingrovePermissionKind.inputMonitoring.rawValue, "Privacy_ListenEvent")
        XCTAssertEqual(LingrovePermissionKind.screenRecording.rawValue, "Privacy_ScreenCapture")
    }

    func test_presentationCopy_isPinnedPerPermission() {
        let expectations: [(kind: LingrovePermissionKind, title: String, image: String, subtitle: String)] = [
            (.accessibility, "Accessibility", "accessibility", "Read text fields and caret position."),
            (.inputMonitoring, "Input Monitoring", "keyboard.fill", "Detect typing and accept with Tab."),
            (
                .screenRecording,
                "Screen Recording",
                "rectangle.dashed.badge.record",
                "Optional: screen context and OCR translation."
            )
        ]

        for expectation in expectations {
            XCTAssertEqual(expectation.kind.title, expectation.title, "\(expectation.kind) title")
            XCTAssertEqual(expectation.kind.systemImageName, expectation.image, "\(expectation.kind) image")
            XCTAssertEqual(expectation.kind.onboardingSubtitle, expectation.subtitle, "\(expectation.kind) subtitle")
        }
    }

    func test_settingsURL_usesExpectedDeepLinkFormat() {
        for kind in LingrovePermissionKind.allCases {
            let expected = "x-apple.systempreferences:com.apple.preference.security?\(kind.rawValue)"
            XCTAssertEqual(kind.settingsURL.absoluteString, expected)
        }
    }

    func test_guidanceStyle_isGuidedOverlayForAllCases() {
        for kind in LingrovePermissionKind.allCases {
            XCTAssertEqual(kind.guidanceStyle, .guidedOverlay, "\(kind)")
        }
    }

    func test_isRequiredForAutocomplete_isTrueOnlyForCoreInputPermissions() {
        XCTAssertTrue(LingrovePermissionKind.accessibility.isRequiredForAutocomplete)
        XCTAssertTrue(LingrovePermissionKind.inputMonitoring.isRequiredForAutocomplete)
        // Screen Recording is optional: missing it forces the text-only Fast Mode path rather than
        // disabling autocomplete.
        XCTAssertFalse(LingrovePermissionKind.screenRecording.isRequiredForAutocomplete)
    }

    func test_isOptionalEnhancement_isTrueOnlyForScreenRecording() {
        XCTAssertTrue(LingrovePermissionKind.screenRecording.isOptionalEnhancement)
        XCTAssertFalse(LingrovePermissionKind.accessibility.isOptionalEnhancement)
        XCTAssertFalse(LingrovePermissionKind.inputMonitoring.isOptionalEnhancement)
    }

    func test_compactRowTitle_appendsOptionalQualifierOnlyForEnhancements() {
        // Compact rows reuse the required rows' styling, so this suffix is the only thing that
        // marks Screen Recording as optional there.
        XCTAssertEqual(LingrovePermissionKind.accessibility.compactRowTitle, "Accessibility")
        XCTAssertEqual(LingrovePermissionKind.inputMonitoring.compactRowTitle, "Input Monitoring")
        XCTAssertEqual(LingrovePermissionKind.screenRecording.compactRowTitle, "Screen Recording (Optional)")
    }
}

/// Pins the screenshot/OCR budgets and the engine-to-profile privacy mapping.
final class VisualContextModelTests: XCTestCase {

    func test_defaultConfiguration_hasExpectedValues() {
        let config = VisualContextConfiguration.default
        XCTAssertEqual(config.snapshotDimension, 700)
        // 1200 is the measured-tradeoff OCR input cap; see the rationale on the default config.
        XCTAssertEqual(config.maxImageDimension, 1200)
        XCTAssertEqual(config.minRecognizedCharacterCount, 12)
        XCTAssertEqual(config.maxRecognizedCharacters, 5000)
        XCTAssertEqual(config.maxSummaryCharacters, 1500)
        XCTAssertFalse(config.capturesEntireWindow)
    }

    func test_localConfiguration_widensCaptureAndBudgetsForOnDeviceEngines() {
        let config = VisualContextConfiguration.local
        XCTAssertEqual(config.snapshotDimension, 700)
        XCTAssertEqual(config.maxImageDimension, 2400)
        XCTAssertEqual(config.minRecognizedCharacterCount, 12)
        XCTAssertEqual(config.maxRecognizedCharacters, 12000)
        XCTAssertEqual(config.maxSummaryCharacters, 4000)
        XCTAssertTrue(config.capturesEntireWindow)
    }

    func test_forEngine_keepsTheNetworkEndpointOnTheNarrowDefaultProfile() {
        // Choosing a network backend is not consent to send a wider screenshot's worth of text.
        XCTAssertEqual(VisualContextConfiguration.forEngine(.openAICompatible), .default)
        XCTAssertEqual(VisualContextConfiguration.forEngine(.appleIntelligence), .local)
        XCTAssertEqual(VisualContextConfiguration.forEngine(.llamaOpenSource), .local)
    }
}
