import Foundation

/// Fixed, localized account presentation shared by Settings and its accessibility output.
/// Network and Keychain failures arrive as closed categories, so private server diagnostics
/// cannot accidentally cross a plain String boundary into the user interface.
enum AccountPresentation {
    static func title(_ state: AccountSessionState) -> String {
        switch state {
        case .unconfigured: String(localized: "Not configured", table: "Account")
        case .signedOut: String(localized: "Signed out", table: "Account")
        case .awaitingCode: String(localized: "Waiting for your code", table: "Account")
        case .working(.sendingCode): String(localized: "Requesting a code…", table: "Account")
        case .working(.verifyingCode): String(localized: "Confirming your identity…", table: "Account")
        case .working(.restoring): String(localized: "Restoring your session…", table: "Account")
        case .working(.refreshing): String(localized: "Refreshing your session…", table: "Account")
        case .signedIn: String(localized: "Signed in", table: "Account")
        case .offline: String(localized: "Session needs recovery", table: "Account")
        case .credentialsInvalid: String(localized: "Sign in again", table: "Account")
        }
    }

    // An exhaustive copy map should keep one branch per closed error category.
    // swiftlint:disable:next cyclomatic_complexity
    static func message(_ issue: AccountIssue) -> String {
        switch issue {
        case .invalidConfiguration:
            String(localized: """
                Enter valid API and authentication base URLs. Use HTTPS, or HTTP on loopback for local testing.
                """, table: "Account")
        case .invalidEmail: String(localized: "Enter a valid email address.", table: "Account")
        case .invalidCode: String(localized: "Enter the eight-digit code from your email.", table: "Account")
        case .codeExpired: String(localized: "This code has expired. Request a new code.", table: "Account")
        case .codeConsumed: String(localized: "This code has already been used. Request a new code.", table: "Account")
        case .tooManyAttempts: String(localized: "Too many incorrect attempts. Request a new code and try again.", table: "Account")
        case .rateLimited: String(localized: "Too many requests. Wait a moment and try again.", table: "Account")
        case .network: String(localized: "The account service could not be reached. Check your connection and try again.", table: "Account")
        case .serviceUnavailable: String(localized: "The account service is temporarily unavailable. Try again later.", table: "Account")
        case .invalidResponse: String(localized: """
            The account service returned an unexpected response. Check the connection settings and retry.
            """, table: "Account")
        case .credentialsInvalid: String(localized: "Your saved session is no longer valid. Sign in again.", table: "Account")
        case .identityChanged: String(localized: """
            The service returned a different account. Sign in again to confirm your identity.
            """, table: "Account")
        case .secureStorage: String(localized: """
            The private Keychain could not be accessed. Retry when it is available. Local sign-out will not \
            restore this session.
            """, table: "Account")
        case .cancelled: String(localized: "The account operation was cancelled.", table: "Account")
        }
    }
}
