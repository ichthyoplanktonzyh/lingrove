import Testing
@testable import Lingrove

struct LingroveTestHostPolicyTests {
    @Test func validationCopiesStayIsolatedWithoutChangingNormalAppAdmission() {
        #expect(LingroveTestHostPolicy.isActive(environment: ["XCTestConfigurationFilePath": "synthetic"],
            bundleIdentifier: "example.app", validationFlag: false))
        #expect(LingroveTestHostPolicy.isActive(environment: [:],
            bundleIdentifier: "example.app.validation", validationFlag: true))
        #expect(!LingroveTestHostPolicy.isActive(environment: [:],
            bundleIdentifier: "io.ichthyoplanktonzyh.lingrove.dev", validationFlag: false))
        #expect(!LingroveTestHostPolicy.isActive(environment: [:],
            bundleIdentifier: "example.app.validation", validationFlag: false))
        #expect(!LingroveTestHostPolicy.isActive(environment: [:],
            bundleIdentifier: "io.ichthyoplanktonzyh.lingrove.dev", validationFlag: true))
    }
}
