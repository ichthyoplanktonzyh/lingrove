import Foundation

/// The explicit pair of services selected in Account settings. There is no official-service
/// default: an untouched installation neither contacts an account host nor creates a cloud guest.
/// The same value scopes Keychain storage, so tokens never follow an edited URL to another host.
public nonisolated struct AccountServiceConfiguration: Codable, Equatable, Sendable {
    public init(apiBaseURL: URL, authBaseURL: URL) {
        self.apiBaseURL = apiBaseURL; self.authBaseURL = authBaseURL
    }
    public let apiBaseURL: URL
    public let authBaseURL: URL
}

/// Only an authenticated `/me` response creates this identity. It is account metadata, not local
/// notebook ownership or evidence that any data has synced. Views receive this value without tokens.
public nonisolated struct AccountIdentity: Codable, Equatable, Sendable {
    public init(userID: String, email: String?, canonicalAccountID: String?) {
        self.userID = userID; self.email = email; self.canonicalAccountID = canonicalAccountID
    }
    public let userID: String
    public let email: String?
    public let canonicalAccountID: String?
}

/// Private session material exchanged by the transport and the app-owned session service.
/// Expiry comes from the auth response; parsing a JWT is deliberately not an identity check.
public nonisolated struct AccountCredentials: Codable, Equatable, Sendable {
    public init(idToken: String, refreshToken: String, expiresAt: Date) {
        self.idToken = idToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
    public let idToken: String
    public let refreshToken: String
    public let expiresAt: Date
}

/// Keychain keeps the last confirmed identity with its credentials. A newly verified OTP can have
/// no identity yet if `/me` is offline; it remains pending rather than falsely becoming signed in.
public nonisolated struct AccountStoredSession: Codable, Equatable, Sendable {
    public init(configuration: AccountServiceConfiguration, credentials: AccountCredentials, identity: AccountIdentity?) {
        self.configuration = configuration; self.credentials = credentials; self.identity = identity
    }
    public let configuration: AccountServiceConfiguration
    public let credentials: AccountCredentials
    public let identity: AccountIdentity?
}

/// Secrets for one native OTP attempt. They stay in the service, never in the observable UI state.
/// Nibomo's existing native protocol sends both fields in the verify body rather than using cookies.
public nonisolated struct AccountOTPChallenge: Equatable, Sendable {
    public init(email: String, csrfToken: String, otpSessionToken: String, expiresAt: Date) {
        self.email = email; self.csrfToken = csrfToken
        self.otpSessionToken = otpSessionToken; self.expiresAt = expiresAt
    }
    public let email: String
    public let csrfToken: String
    public let otpSessionToken: String
    public let expiresAt: Date
}

/// The safe presentation projection of an OTP challenge survives closing/reopening Settings.
public nonisolated struct AccountCodePrompt: Equatable, Sendable {
    public init(email: String, expiresAt: Date, isExpired: Bool = false) {
        self.email = email; self.expiresAt = expiresAt; self.isExpired = isExpired
    }
    public let email: String
    public let expiresAt: Date
    public var isExpired = false
}

/// `send-code` also supports an immediate session in the fixed auth contract (local auth mode).
/// Both branches still require the same server-side `/me` confirmation on Mac.
public nonisolated enum AccountSendCodeResult: Equatable, Sendable {
    case challenge(AccountOTPChallenge)
    case credentials(AccountCredentials)
}

/// Mutually exclusive UI states make an offline saved session visibly different from a verified
/// online identity. No case implies notebook adoption, workspace selection, or synchronization.
public nonisolated enum AccountSessionState: Equatable, Sendable {
    case unconfigured
    case signedOut
    case working(AccountActivity)
    case awaitingCode
    case signedIn(AccountIdentity)
    case offline(AccountIdentity?)
    case credentialsInvalid

    public var isBusy: Bool {
        if case .working = self { return true }
        return false
    }
}

/// Activities belong to the account service's task lifetime, rather than a particular window.
public nonisolated enum AccountActivity: Equatable, Sendable {
    case sendingCode, verifyingCode, restoring, refreshing
}

/// Fixed error categories cross the network/storage boundary. Raw response bodies, tokens,
/// server error messages and URLs containing user input never become settings copy or logs.
public nonisolated enum AccountIssue: Error, Equatable, Sendable {
    case invalidConfiguration, invalidEmail, invalidCode, codeExpired, codeConsumed
    case tooManyAttempts, rateLimited, network, serviceUnavailable, invalidResponse
    case credentialsInvalid, identityChanged, secureStorage, cancelled
}

/// A short-lived capability borrowed from a confirmed session. It is private network input,
/// not a UI model, persisted owner decision, or substitute for a notebook binding.
public nonisolated struct AccountAuthorization: Sendable {
    public let configuration: AccountServiceConfiguration
    public let identity: AccountIdentity
    public let idToken: String
    public let expiresAt: Date
    public let generation: UInt64
}
