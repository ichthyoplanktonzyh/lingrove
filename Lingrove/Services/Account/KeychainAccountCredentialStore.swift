import LingroveCloud
import Foundation
import LocalAuthentication
import Security

/// Mac's private credential boundary. The login Keychain stores one opaque record for each explicit
/// API/auth pair, under a bundle-specific service and an ACL trusting only the creating application.
/// This fits the existing nonsandboxed AppKit host without a provisioning-profile requirement.
/// Items are not synchronized or shared through an access group; there is no file/UserDefaults
/// fallback, even in tests. Synthetic tests use their own bundle/namespace and clean them up.
@MainActor
final class KeychainAccountCredentialStore: AccountCredentialStoring {
    private let service: String

    init(bundleIdentifier: String, namespace: String = "native-v1") {
        service = "\(bundleIdentifier).account-session.\(namespace)"
    }

    // Explicit until the older supported Xcode toolchains stop emitting isolated-deinit bugs
    // for a main-actor class retained through a protocol existential.
    deinit {}

    func load(configuration: AccountServiceConfiguration) throws -> AccountStoredSession? {
        var query = identity(configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // UI prompts are not appropriate during silent launch restoration. A locked Keychain
        // becomes a recoverable storage issue and leaves the rest of the menu-bar app usable.
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AccountKeychainFailure(operation: "load", status: status) }
        guard let data = item as? Data,
              let session = try? JSONDecoder().decode(AccountStoredSession.self, from: data),
              session.configuration == configuration,
              !session.credentials.idToken.isEmpty, !session.credentials.refreshToken.isEmpty else {
            throw AccountKeychainFailure(operation: "decode", status: errSecDecode)
        }
        // CopyMatching transfers a CF object to Swift; the conditional Data bridge is checked
        // rather than force-cast because a corrupt/unexpected Keychain item must fail closed.
        return session
    }

    func save(_ session: AccountStoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let query = identity(session.configuration)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AccountKeychainFailure(operation: "update", status: status) }
        var insert = query.merging(attributes) { _, new in new }
        insert[kSecAttrAccess as String] = try privateApplicationAccess()
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw AccountKeychainFailure(operation: "save", status: added) }
    }

    func clear(configuration: AccountServiceConfiguration) throws {
        let status = SecItemDelete(identity(configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountKeychainFailure(operation: "clear", status: status)
        }
    }

    private func identity(_ configuration: AccountServiceConfiguration) -> [String: Any] {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: AccountConfigurationPolicy.credentialScope(configuration),
            kSecUseAuthenticationContext as String: authentication
        ]
    }

    private func privateApplicationAccess() throws -> SecAccess {
        // A nil path means this executable. SecTrustedApplication records its code requirement,
        // so stable signed rebuilds remain trusted while a different app cannot silently read it.
        // Both Create calls transfer ownership to ARC-managed Swift references; failure never
        // falls through to a broader trusted list after failing to identify this application.
        var application: SecTrustedApplication?
        let applicationStatus = SecTrustedApplicationCreateFromPath(nil, &application)
        guard applicationStatus == errSecSuccess, let application else {
            throw AccountKeychainFailure(operation: "application-access", status: applicationStatus)
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate("Lingrove private account session" as CFString, [application] as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw AccountKeychainFailure(operation: "private-access", status: accessStatus)
        }
        return access
    }
}

/// Nonsecret diagnostics remain useful in a failing integration test, while the service maps
/// every storage failure to fixed localized copy before publishing it to Settings.
private struct AccountKeychainFailure: Error {
    let operation: String
    let status: OSStatus
}
