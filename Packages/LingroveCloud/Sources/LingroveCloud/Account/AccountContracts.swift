import Foundation

/// Narrow native authentication seam for a future shared account SDK. The app-owned service
/// supplies one configuration per operation; an adapter must never infer an official endpoint.
/// Main-actor isolation serializes session decisions while URLSession handles network waiting.
@MainActor
public protocol AccountAuthenticating: AnyObject {
    func sendCode(email: String, configuration: AccountServiceConfiguration) async throws -> AccountSendCodeResult
    func verifyCode(_ code: String, challenge: AccountOTPChallenge,
                    configuration: AccountServiceConfiguration) async throws -> AccountCredentials
    func refresh(_ credentials: AccountCredentials,
                 configuration: AccountServiceConfiguration) async throws -> AccountCredentials
    func identity(idToken: String, configuration: AccountServiceConfiguration) async throws -> AccountIdentity
}

/// Synchronous storage keeps each save/clear inside one main-actor transaction, with no suspension
/// between checking a session generation and writing it. Production uses private Keychain only.
@MainActor
public protocol AccountCredentialStoring: AnyObject {
    func load(configuration: AccountServiceConfiguration) throws -> AccountStoredSession?
    func save(_ session: AccountStoredSession) throws
    func clear(configuration: AccountServiceConfiguration) throws
}

/// Nonsecret restore authorization stays with the host's settings store. Closing this gate
/// precedes credential deletion, so an unavailable Keychain cannot reactivate a logged-out user.
public nonisolated struct AccountConnectionRecord: Codable, Equatable, Sendable {
    public let configuration: AccountServiceConfiguration
    public var allowsSessionRestore: Bool
    public init(configuration: AccountServiceConfiguration, allowsSessionRestore: Bool) {
        self.configuration = configuration; self.allowsSessionRestore = allowsSessionRestore
    }
}

/// The process-owned session borrows this host adapter; tokens have no path into these methods.
@MainActor
public protocol AccountConfigurationStoring: AnyObject {
    func load() throws -> AccountConnectionRecord?
    func save(_ configuration: AccountServiceConfiguration, allowsSessionRestore: Bool)
    func clear()
}
