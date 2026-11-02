import Foundation

/// Native adapter for the fixed Nibomo email-auth and `/me` wire contracts. The existing mobile
/// CloudAuthService depends on Flashcards-specific logging, errors and database-derived types;
/// this adapter carries only its platform-independent requests into the Mac target. A future
/// shared SDK replaces this seam without importing mobile store/sync ownership into the app.
@MainActor
final class AccountAPIClient: AccountAuthenticating {
    private let session: URLSession
    private let redirects = AccountRedirectPolicy()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    func sendCode(email: String, configuration: AccountServiceConfiguration) async throws -> AccountSendCodeResult {
        let started = Date()
        let response: SendCodeResponse = try await request(base: configuration.authBaseURL, path: "/api/send-code",
            body: SendCodeRequest(email: email))
        guard response.ok else { throw AccountIssue.invalidResponse }
        if let id = response.idToken, let refresh = response.refreshToken, let expiry = response.expiresIn {
            return .credentials(try credentials(id: id, refresh: refresh, expiry: expiry))
        }
        guard let csrf = response.csrfToken, let otp = response.otpSessionToken,
              validSecret(csrf), validSecret(otp), response.idToken == nil, response.refreshToken == nil else {
            throw AccountIssue.invalidResponse
        }
        // Resend throttling can return an older signed envelope. Its display-only timestamp can
        // shorten this local deadline; it never grants a session or replaces `/me` confirmation.
        return .challenge(AccountOTPChallenge(email: email, csrfToken: csrf, otpSessionToken: otp,
            expiresAt: AccountOTPExpiryPolicy.expiry(token: otp, requestedAt: started)))
    }

    func verifyCode(_ code: String, challenge: AccountOTPChallenge,
                    configuration: AccountServiceConfiguration) async throws -> AccountCredentials {
        let response: SessionResponse = try await request(base: configuration.authBaseURL, path: "/api/verify-code",
            body: VerifyCodeRequest(code: code, csrfToken: challenge.csrfToken, otpSessionToken: challenge.otpSessionToken))
        guard response.ok else { throw AccountIssue.invalidResponse }
        return try credentials(id: response.idToken, refresh: response.refreshToken, expiry: response.expiresIn)
    }

    func refresh(_ old: AccountCredentials, configuration: AccountServiceConfiguration) async throws -> AccountCredentials {
        let response: RefreshResponse = try await request(base: configuration.authBaseURL, path: "/api/refresh-token",
            body: RefreshRequest(refreshToken: old.refreshToken))
        guard response.ok else { throw AccountIssue.invalidResponse }
        // Rotation is optional. An explicitly empty replacement is a malformed response, not
        // permission to discard the old token or silently keep a known-bad replacement.
        return try credentials(id: response.idToken, refresh: response.refreshToken ?? old.refreshToken,
            expiry: response.expiresIn)
    }

    func identity(idToken: String, configuration: AccountServiceConfiguration) async throws -> AccountIdentity {
        let response: MeResponse = try await request(base: configuration.apiBaseURL, path: "/me", token: idToken,
            body: Optional<RefreshRequest>.none)
        guard validIdentifier(response.userId),
              response.canonicalAccountId.map(validIdentifier) ?? true,
              response.profile.email.map({ $0.utf8.count <= 320 && !$0.contains(where: { $0.isNewline }) }) ?? true else {
            throw AccountIssue.invalidResponse
        }
        return AccountIdentity(userID: response.userId, email: response.profile.email,
            canonicalAccountID: response.canonicalAccountId)
    }

    private func credentials(id: String, refresh: String, expiry: Int) throws -> AccountCredentials {
        guard validSecret(id), validSecret(refresh), (1...31_536_000).contains(expiry) else {
            throw AccountIssue.invalidResponse
        }
        return AccountCredentials(idToken: id, refreshToken: refresh, expiresAt: Date().addingTimeInterval(Double(expiry)))
    }

    private func validSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32_768 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    private func request<Response: Decodable, Body: Encodable>(
        base: URL, path: String, token: String? = nil, body: Body?
    ) async throws -> Response {
        try Task.checkCancellation()
        // Revalidate restored values too; only HTTPS or explicit loopback HTTP may carry secrets.
        let safeBase = try AccountConfigurationPolicy.baseURL(base.absoluteString)
        guard let url = URL(string: safeBase.absoluteString + path) else { throw AccountIssue.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await Self.boundedResponse(session: session, request: request, redirects: redirects)
        } catch {
            if let issue = error as? AccountIssue { throw issue }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw AccountIssue.cancelled }
            throw AccountIssue.network
        }
        try Task.checkCancellation()
        let http = response
        guard (200..<300).contains(http.statusCode) else {
            // Decode only the stable machine code. The backend's human message may contain
            // private diagnostics and is never surfaced or recorded by the Mac adapter.
            let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.code
            throw issue(status: http.statusCode, code: code)
        }
        guard let value = try? JSONDecoder().decode(Response.self, from: data) else { throw AccountIssue.invalidResponse }
        return value
    }

    /// Byte iteration has a strict in-memory ceiling and runs away from UI state. Refusing a
    /// declared size early is only an optimization; chunked/decompressed bodies obey the same
    /// accumulated limit. The owned request is cancelled on overflow, cancellation and completion.
    @concurrent
    private static func boundedResponse(session: URLSession, request: URLRequest,
                                        redirects: AccountRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
        let maximumBytes = 512 * 1024
        let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= Int64(maximumBytes) else { throw AccountIssue.invalidResponse }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw AccountIssue.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }

    private func issue(status: Int, code: String?) -> AccountIssue {
        switch code {
        case "INVALID_EMAIL": return .invalidEmail
        case "OTP_CODE_INVALID": return .invalidCode
        case "OTP_SESSION_EXPIRED": return .codeExpired
        case "OTP_CHALLENGE_CONSUMED": return .codeConsumed
        case "OTP_TOO_MANY_ATTEMPTS": return .tooManyAttempts
        default:
            if [401, 403, 410].contains(status) { return .credentialsInvalid }
            if status == 429 { return .rateLimited }
            if status >= 500 { return .serviceUnavailable }
            return .invalidResponse
        }
    }
}

/// Redirects are refused even when the new host is also HTTPS. A configuration authorizes the
/// selected service, not a redirect destination that could receive OTP or refresh-token bodies.
private final class AccountRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// These small wire values intentionally mirror only the fixed authentication contract. Extra
// `/me` fields (preferences/workspaces) are ignored; reading identity never adopts notebook data.
private struct SendCodeRequest: Encodable { let email: String }
private struct VerifyCodeRequest: Encodable { let code: String; let csrfToken: String; let otpSessionToken: String }
private struct RefreshRequest: Encodable { let refreshToken: String }
private struct SendCodeResponse: Decodable {
    let ok: Bool
    let csrfToken: String?
    let otpSessionToken: String?
    let idToken: String?
    let refreshToken: String?
    let expiresIn: Int?
}
private struct SessionResponse: Decodable { let ok: Bool; let idToken: String; let refreshToken: String; let expiresIn: Int }
private struct RefreshResponse: Decodable { let ok: Bool; let idToken: String; let refreshToken: String?; let expiresIn: Int }
private struct ErrorResponse: Decodable { let code: String? }
private struct MeResponse: Decodable {
    struct Profile: Decodable { let email: String? }
    let userId: String
    let canonicalAccountId: String?
    let profile: Profile
}
