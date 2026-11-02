import CryptoKit
import Foundation

/// Pure connection validation and credential scoping. Keeping this outside the window and
/// Keychain makes the same transport/privacy rules apply to typed settings and restored settings.
nonisolated enum AccountConfigurationPolicy {
    static func configuration(api: String, auth: String) throws -> AccountServiceConfiguration {
        AccountServiceConfiguration(apiBaseURL: try baseURL(api), authBaseURL: try baseURL(auth))
    }

    /// A connection form is only a draft until it matches the saved service pair. In particular,
    /// a failed Keychain clear keeps the old pair active; typing a new URL must not authorize
    /// sending an email/code to that old service while the window shows the new destination.
    static func matchesSavedConnection(api: String, auth: String,
                                       saved: AccountServiceConfiguration?) -> Bool {
        guard let saved, let draft = try? configuration(api: api, auth: auth) else { return false }
        return draft == saved
    }

    static func baseURL(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
              !components.percentEncodedPath.contains("%"),
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw AccountIssue.invalidConfiguration
        }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw AccountIssue.invalidConfiguration }
        return url
    }

    /// A digest is an opaque Keychain account name, not an encryption mechanism. The Keychain
    /// service separately includes the app bundle and namespace to isolate Dev/prod/test callers.
    static func credentialScope(_ configuration: AccountServiceConfiguration) -> String {
        let scope = configuration.apiBaseURL.absoluteString + "\n" + configuration.authBaseURL.absoluteString
        return SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedEmail(_ email: String) throws -> String {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
        guard value.utf8.count <= 254, pieces.count == 2, !pieces[0].isEmpty,
              pieces[1].contains("."), !pieces[1].hasPrefix("."), !pieces[1].hasSuffix("."),
              !value.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map({ $0 < 32 }) == true }) else {
            throw AccountIssue.invalidEmail
        }
        return value
    }

    static func normalizedCode(_ code: String) throws -> String {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count == 8, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw AccountIssue.invalidCode
        }
        return value
    }
}
