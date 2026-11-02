import Foundation

/// The explicit pair of services selected in Account settings. There is no official-service
/// default: an untouched installation neither contacts an account host nor creates a cloud guest.
/// The same value scopes Keychain storage, so tokens never follow an edited URL to another host.
nonisolated struct AccountServiceConfiguration: Codable, Equatable, Sendable {
    let apiBaseURL: URL
    let authBaseURL: URL
}

/// Only an authenticated `/me` response creates this identity. It is account metadata, not local
/// notebook ownership or evidence that any data has synced. Views receive this value without tokens.
nonisolated struct AccountIdentity: Codable, Equatable, Sendable {
    let userID: String
    let email: String?
    let canonicalAccountID: String?
}

/// Private session material exchanged by the transport and the app-owned session service.
/// Expiry comes from the auth response; parsing a JWT is deliberately not an identity check.
nonisolated struct AccountCredentials: Codable, Equatable, Sendable {
    let idToken: String
    let refreshToken: String
    let expiresAt: Date
}

/// Keychain keeps the last confirmed identity with its credentials. A newly verified OTP can have
/// no identity yet if `/me` is offline; it remains pending rather than falsely becoming signed in.
nonisolated struct AccountStoredSession: Codable, Equatable, Sendable {
    let configuration: AccountServiceConfiguration
    let credentials: AccountCredentials
    let identity: AccountIdentity?
}

/// Secrets for one native OTP attempt. They stay in the service, never in the observable UI state.
/// Nibomo's existing native protocol sends both fields in the verify body rather than using cookies.
nonisolated struct AccountOTPChallenge: Equatable, Sendable {
    let email: String
    let csrfToken: String
    let otpSessionToken: String
    let expiresAt: Date
}

/// The safe presentation projection of an OTP challenge survives closing/reopening Settings.
nonisolated struct AccountCodePrompt: Equatable, Sendable {
    let email: String
    let expiresAt: Date
    var isExpired = false
}

/// `send-code` also supports an immediate session in the fixed auth contract (local auth mode).
/// Both branches still require the same server-side `/me` confirmation on Mac.
nonisolated enum AccountSendCodeResult: Equatable, Sendable {
    case challenge(AccountOTPChallenge)
    case credentials(AccountCredentials)
}

/// Mutually exclusive UI states make an offline saved session visibly different from a verified
/// online identity. No case implies notebook adoption, workspace selection, or synchronization.
nonisolated enum AccountSessionState: Equatable, Sendable {
    case unconfigured
    case signedOut
    case working(AccountActivity)
    case awaitingCode
    case signedIn(AccountIdentity)
    case offline(AccountIdentity?)
    case credentialsInvalid

    var isBusy: Bool {
        if case .working = self { return true }
        return false
    }
}

/// Activities belong to the account service's task lifetime, rather than a particular window.
nonisolated enum AccountActivity: Equatable, Sendable {
    case sendingCode, verifyingCode, restoring, refreshing
}

/// Fixed error categories cross the network/storage boundary. Raw response bodies, tokens,
/// server error messages and URLs containing user input never become settings copy or logs.
nonisolated enum AccountIssue: Error, Equatable, Sendable {
    case invalidConfiguration, invalidEmail, invalidCode, codeExpired, codeConsumed
    case tooManyAttempts, rateLimited, network, serviceUnavailable, invalidResponse
    case credentialsInvalid, identityChanged, secureStorage, cancelled
}
