import Foundation
import LingroveCloud
import Testing
@testable import Lingrove

/// Info.plist is the app's only bundled service input. These pure cases prove a partial,
/// malformed or unresolved build value cannot authorize a network destination.
struct AccountBuildConfigurationTests {
    @Test func absentAndBlankBuildValuesHaveNoService() {
        #expect(AccountBuildConfiguration(infoDictionary: [:]) == .missing)
        #expect(AccountBuildConfiguration(infoDictionary: ["LingroveAccountAPIBaseURL": " \n",
            "LingroveAccountAuthBaseURL": ""]) == .missing)
    }

    @Test(arguments: [
        ["LingroveAccountAPIBaseURL": "https://api.example.invalid/v1"],
        ["LingroveAccountAuthBaseURL": "https://auth.example.invalid"],
        ["LingroveAccountAPIBaseURL": "$(LINGROVE_ACCOUNT_API_BASE_URL)",
         "LingroveAccountAuthBaseURL": "$(LINGROVE_ACCOUNT_AUTH_BASE_URL)"],
        ["LingroveAccountAPIBaseURL": "http://public.example.invalid/v1",
         "LingroveAccountAuthBaseURL": "https://auth.example.invalid"],
        ["LingroveAccountAPIBaseURL": "https://api.example.invalid/v1",
         "LingroveAccountAuthBaseURL": "https://auth.example.invalid?token=private"]
    ])
    func partialAndUnsafePairsFailClosed(_ values: [String: String]) {
        #expect(AccountBuildConfiguration(infoDictionary: values) == .invalid)
    }

    @Test func buildValuesUseSharedCanonicalizationAndRejectWrongPlistTypes() throws {
        let configured = AccountBuildConfiguration(infoDictionary: ["LingroveAccountAPIBaseURL": " HTTPS://API.EXAMPLE.INVALID:443/v1/ ",
            "LingroveAccountAuthBaseURL": "https://auth.example.invalid/"])
        #expect(configured.configuration == (try AccountConfigurationPolicy.configuration(api: "https://api.example.invalid/v1",
            auth: "https://auth.example.invalid")))
        #expect(AccountBuildConfiguration(infoDictionary: ["LingroveAccountAPIBaseURL": 42]) == .invalid)
    }
}
