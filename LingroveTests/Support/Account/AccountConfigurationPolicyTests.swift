import Foundation
import Testing
@testable import Lingrove

/// Connection validation is shared by UI, restoration and transport. These cases protect the
/// credential boundary rather than duplicating presentation implementation details.
struct AccountConfigurationPolicyTests {
    @Test
    func connectionsAreExplicitCanonicalAndScopedToBothServices() throws {
        let first = try AccountConfigurationPolicy.configuration(api: " HTTPS://API.EXAMPLE.INVALID:443/v1/ ", auth: "https://auth.example.invalid/")
        let second = try AccountConfigurationPolicy.configuration(api: "https://api.example.invalid/v1", auth: "https://auth.example.invalid")
        #expect(first == second)
        #expect(AccountConfigurationPolicy.credentialScope(first) == AccountConfigurationPolicy.credentialScope(second))
        let changed = try AccountConfigurationPolicy.configuration(api: "https://api.example.invalid/v1", auth: "https://other.example.invalid")
        #expect(AccountConfigurationPolicy.credentialScope(first) != AccountConfigurationPolicy.credentialScope(changed))
        _ = try AccountConfigurationPolicy.configuration(api: "http://127.0.0.1:18980/v1", auth: "http://localhost:18981")
        for unsafe in ["http://public.example.invalid", "https://user:secret@example.invalid", "https://host.invalid?secret=token",
                       "https://host.invalid/#fragment", "file:///tmp/auth", "https://host.invalid/a/../b"] {
            #expect(throws: AccountIssue.invalidConfiguration) { try AccountConfigurationPolicy.baseURL(unsafe) }
        }
    }

    @Test
    func resentOTPEnvelopeCannotRenewItsOriginalExpiryOrProveIdentity() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONEncoder().encode(["t": start.timeIntervalSince1970 * 1_000])
        let token = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".synthetic-signature"
        let initial = AccountOTPExpiryPolicy.expiry(token: token, requestedAt: start)
        let resent = AccountOTPExpiryPolicy.expiry(token: token, requestedAt: start.addingTimeInterval(170))
        #expect(initial == start.addingTimeInterval(180))
        #expect(resent == initial)
        #expect(AccountOTPExpiryPolicy.expiry(token: "opaque", requestedAt: start) == initial)
    }
}
