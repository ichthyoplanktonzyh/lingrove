import Foundation

/// One process-lifetime account state machine borrowed by native hosts. The host injects
/// private credential/settings adapters and observes safe projections; opening a window never
/// creates a second refresh owner. No UI framework or default service is imported here.
///
/// Every suspension is fenced by `generation`. Cancellation alone cannot reject an already
/// delivered URLSession callback, so logout/configuration changes also retire its right to commit.
@MainActor
public final class AccountSession {
    public private(set) var configuration: AccountServiceConfiguration? { didSet { onChange?() } }
    public private(set) var state: AccountSessionState = .unconfigured { didSet { onChange?() } }
    public private(set) var codePrompt: AccountCodePrompt? { didSet { onChange?() } }
    public private(set) var issue: AccountIssue? { didSet { onChange?() } }

    /// The host observes only safe projections, keeping Combine/SwiftUI out of the library.
    public var onChange: (@MainActor () -> Void)?

    private let client: any AccountAuthenticating
    private let credentials: any AccountCredentialStoring
    private let settings: any AccountConfigurationStoring
    private var savedSession: AccountStoredSession?
    private var challenge: AccountOTPChallenge?
    public private(set) var generation: UInt64 = 0 { didSet { onChange?() } }
    /// A safe cached identity permits the host to keep an already-owned local workspace visible
    /// during offline restore. It never authorizes a request; only `authorization` does that.
    public var retainedIdentity: AccountIdentity? { savedSession?.identity }
    private var operation: Task<Void, Never>?
    private var recovery: Task<AccountIdentity, Error>?
    private var recoveryID: UUID?
    private var refreshTimer: Task<Void, Never>?
    private var challengeTimer: Task<Void, Never>?
    private var didStart = false

    public init(
        client: any AccountAuthenticating, credentials: any AccountCredentialStoring,
        settings: any AccountConfigurationStoring
    ) {
        self.client = client
        self.credentials = credentials
        self.settings = settings
        do {
            configuration = try settings.load()?.configuration
            state = configuration == nil ? .unconfigured : .signedOut
        } catch {
            issue = .invalidConfiguration
        }
    }

    /// Startup restores only a session explicitly enabled by a previous successful credential
    /// save. No configuration or no saved session means no account network traffic at launch.
    public func start() {
        guard !didStart else { return }
        didStart = true
        guard let configuration else { return }
        do {
            guard try settings.load()?.allowsSessionRestore == true else { return }
            guard let stored = try credentials.load(configuration: configuration) else {
                settings.save(configuration, allowsSessionRestore: false)
                state = .credentialsInvalid
                issue = .credentialsInvalid
                return
            }
            savedSession = stored
            retrySession()
        } catch {
            state = .offline(nil)
            issue = .secureStorage
        }
    }

    /// App shutdown retires in-flight callbacks without logging out the durable session. The next
    /// process still confirms `/me`; an identity is never trusted solely because it was persisted.
    public func shutdown() {
        retireWork()
        didStart = false
    }

    /// Applying a connection is a local identity boundary. Validation happens before mutation;
    /// once accepted, old credentials cannot be sent to the new API or resurrected by old tasks.
    @discardableResult
    public func configure(api: String, auth: String) -> Bool {
        let next: AccountServiceConfiguration
        do { next = try AccountConfigurationPolicy.configuration(api: api, auth: auth) } catch {
            issue = .invalidConfiguration
            return false
        }
        guard next != configuration else { return true }
        let previous = configuration
        retireWork()
        clearMemory()
        if let previous {
            settings.save(previous, allowsSessionRestore: false)
            do { try credentials.clear(configuration: previous) } catch {
                // Keep the old scope addressable until deletion succeeds. Otherwise a failed
                // service switch would strand credentials that no visible control could clear.
                state = .signedOut
                issue = .secureStorage
                return false
            }
        }
        configuration = next
        settings.save(next, allowsSessionRestore: false)
        state = .signedOut
        issue = nil
        return true
    }

    @discardableResult
    public func removeConfiguration() -> Bool {
        let previous = configuration
        retireWork()
        clearMemory()
        if let previous {
            settings.save(previous, allowsSessionRestore: false)
            do { try credentials.clear(configuration: previous) } catch {
                state = .signedOut
                issue = .secureStorage
                return false
            }
        }
        settings.clear()
        configuration = nil
        state = .unconfigured
        issue = nil
        return true
    }

    public func requestCode(email: String) {
        guard let configuration, !state.isBusy else { return }
        // A verified identity must first be deliberately signed out. This also protects future
        // SDK callers from accidentally replacing an active account while editing an email field.
        if case .signedIn = state { return }
        let normalized: String
        do { normalized = try AccountConfigurationPolicy.normalizedEmail(email) } catch {
            issue = .invalidEmail
            return
        }
        retireWork()
        clearMemory()
        settings.save(configuration, allowsSessionRestore: false)
        do { try credentials.clear(configuration: configuration) } catch {
            state = .signedOut
            issue = .secureStorage
            return
        }
        let ticket = generation
        state = .working(.sendingCode)
        issue = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.sendCode(email: normalized, configuration: configuration)
                try check(ticket)
                switch result {
                case .challenge(let challenge):
                    self.challenge = challenge
                    codePrompt = AccountCodePrompt(email: challenge.email, expiresAt: challenge.expiresAt,
                        isExpired: challenge.expiresAt <= Date())
                    state = .awaitingCode
                    scheduleChallengeExpiry(challenge, ticket: ticket)
                case .credentials(let credentials):
                    try await completeSignIn(credentials, configuration: configuration, ticket: ticket)
                }
            } catch {
                guard ticket == generation else { return }
                handleSignInFailure(error)
            }
            if ticket == generation { operation = nil }
        }
    }

    public func resendCode() {
        guard let email = codePrompt?.email, !state.isBusy else { return }
        requestCode(email: email)
    }

    public func submitCode(_ code: String) {
        guard let configuration, let challenge, !state.isBusy else { return }
        guard challenge.expiresAt > Date(), codePrompt?.isExpired == false else {
            expireChallenge()
            return
        }
        let normalized: String
        do { normalized = try AccountConfigurationPolicy.normalizedCode(code) } catch {
            issue = .invalidCode
            return
        }
        let ticket = generation
        state = .working(.verifyingCode)
        issue = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let tokens = try await client.verifyCode(normalized, challenge: challenge, configuration: configuration)
                try check(ticket)
                try await completeSignIn(tokens, configuration: configuration, ticket: ticket)
            } catch {
                guard ticket == generation else { return }
                handleSignInFailure(error)
            }
            if ticket == generation { operation = nil }
        }
    }

    /// Cancel is local: the protocol has no OTP-cancel endpoint. Retiring the attempt removes its
    /// secrets and commit rights; the server challenge expires under its existing three-minute TTL.
    public func cancelSignIn() {
        guard codePrompt != nil || state == .working(.sendingCode) || state == .working(.verifyingCode) else { return }
        signOut()
    }

    /// Matches the existing native local-signout semantics. No invented delete/global-signout API
    /// is called and no claim is made about other devices. The restore gate is closed before the
    /// Keychain call, so a deletion failure is visible yet cannot log this Mac back in on restart.
    public func signOut() {
        retireWork()
        clearMemory()
        issue = nil
        state = configuration == nil ? .unconfigured : .signedOut
        guard let configuration else { return }
        settings.save(configuration, allowsSessionRestore: false)
        do { try credentials.clear(configuration: configuration) } catch { issue = .secureStorage }
    }

    public func retrySession() {
        guard configuration != nil, operation == nil, recovery == nil, codePrompt == nil else { return }
        let ticket = generation
        // Publish restoration before scheduling its task. A host starting beside us must not
        // mistake the short scheduling gap for an explicit sign-out of the retained local scope.
        if savedSession != nil { state = .working(.restoring) }
        operation = Task { [weak self] in
            guard let self else { return }
            _ = try? await confirmedIdentity(recheck: true)
            if ticket == generation { operation = nil }
        }
    }

    /// Native wake/activation may recover a previously authorized session, but never starts login
    /// for an unconfigured/signed-out installation. Offline retries remain explicit in Settings.
    public func resumeIfNeeded() {
        guard case .signedIn = state, let savedSession,
              savedSession.credentials.expiresAt <= Date().addingTimeInterval(60) else { return }
        retrySession()
    }

    /// The stable SDK-facing identity seam deduplicates every restore/refresh caller. Only the
    /// single task commits rotation and `/me`, so concurrent consumers cannot reuse an old refresh
    /// token. A cancelling consumer cannot cancel the app-owned flight for all other consumers.
    public func confirmedIdentity(recheck: Bool = false, forceRefresh: Bool = false) async throws -> AccountIdentity {
        try Task.checkCancellation()
        let ticket = generation
        // An SDK consumer cannot turn a pending email challenge into restoration. Login owns
        // its own commit path until `/me` succeeds, even if another feature asks for identity.
        guard codePrompt == nil, state != .working(.sendingCode), state != .working(.verifyingCode) else {
            throw AccountIssue.cancelled
        }
        if let recovery {
            let identity = try await recovery.value
            try check(ticket)
            return identity
        }
        if !recheck, !forceRefresh, case .signedIn(let identity) = state,
           let savedSession, savedSession.credentials.expiresAt > Date().addingTimeInterval(60) { return identity }
        guard let configuration else { throw AccountIssue.invalidConfiguration }
        let identifier = UUID()
        let task = Task { [weak self] () throws -> AccountIdentity in
            guard let self else { throw AccountIssue.cancelled }
            defer {
                if recoveryID == identifier { recovery = nil; recoveryID = nil }
            }
            do {
                return try await recover(configuration: configuration, forceRefresh: forceRefresh, ticket: ticket)
            } catch {
                guard ticket == generation else { throw AccountIssue.cancelled }
                handleSessionFailure(error)
                throw error
            }
        }
        recoveryID = identifier
        recovery = task
        let identity = try await task.value
        try check(ticket)
        return identity
    }

    /// Network consumers borrow an authorization after the same single-flight identity check.
    /// This does not select a workspace or authorize corpus adoption. The captured generation
    /// must still be compared by the host when a response returns.
    public func authorization(forceRefresh: Bool = false) async throws -> AccountAuthorization {
        let ticket = generation
        let expectedConfiguration = configuration
        let identity = try await confirmedIdentity(forceRefresh: forceRefresh)
        try check(ticket)
        // The waiter itself can resume after logout + another login, even when the shared
        // recovery task finished before logout. Never pair that old identity with newer tokens.
        guard let savedSession, case .signedIn(let currentIdentity) = state,
              savedSession.configuration == expectedConfiguration,
              savedSession.identity == identity, currentIdentity == identity else { throw AccountIssue.cancelled }
        return AccountAuthorization(configuration: savedSession.configuration, identity: identity,
            idToken: savedSession.credentials.idToken, expiresAt: savedSession.credentials.expiresAt, generation: generation)
    }

    private func completeSignIn(_ tokens: AccountCredentials, configuration: AccountServiceConfiguration,
                                ticket: UInt64) async throws {
        try check(ticket)
        // Persist the exchanged tokens before `/me`: an offline identity API must not strand a
        // consumed OTP. This record has no confirmed identity and can only render pending/offline.
        let pending = AccountStoredSession(configuration: configuration, credentials: tokens, identity: nil)
        try persist(pending)
        challengeTimer?.cancel()
        challenge = nil
        codePrompt = nil
        let identity = try await client.identity(idToken: tokens.idToken, configuration: configuration)
        try check(ticket)
        try accept(identity, credentials: tokens, configuration: configuration)
    }

    private func recover(configuration: AccountServiceConfiguration, forceRefresh: Bool,
                         ticket: UInt64) async throws -> AccountIdentity {
        try check(ticket)
        if savedSession == nil {
            guard try settings.load()?.allowsSessionRestore == true,
                  let stored = try credentials.load(configuration: configuration) else { throw AccountIssue.credentialsInvalid }
            savedSession = stored
        }
        guard var session = savedSession, session.configuration == configuration else { throw AccountIssue.credentialsInvalid }
        state = .working(forceRefresh ? .refreshing : .restoring)
        issue = nil
        var didRefresh = false
        if forceRefresh || session.credentials.expiresAt <= Date().addingTimeInterval(60) {
            session = try await refresh(session, ticket: ticket)
            didRefresh = true
        }
        let identity: AccountIdentity
        do {
            identity = try await client.identity(idToken: session.credentials.idToken, configuration: configuration)
        } catch AccountIssue.credentialsInvalid where !didRefresh {
            try check(ticket)
            session = try await refresh(session, ticket: ticket)
            identity = try await client.identity(idToken: session.credentials.idToken, configuration: configuration)
        }
        try check(ticket)
        if let expected = session.identity, !expected.userID.utf8.elementsEqual(identity.userID.utf8) { throw AccountIssue.identityChanged }
        try accept(identity, credentials: session.credentials, configuration: configuration)
        return identity
    }

    private func refresh(_ session: AccountStoredSession, ticket: UInt64) async throws -> AccountStoredSession {
        state = .working(.refreshing)
        let rotated = try await client.refresh(session.credentials, configuration: session.configuration)
        try check(ticket)
        let next = AccountStoredSession(configuration: session.configuration, credentials: rotated, identity: session.identity)
        // Save rotation before the next network suspension; if `/me` is offline, a restart still
        // uses the replacement refresh token instead of replaying its retired predecessor.
        try persist(next)
        return next
    }

    private func persist(_ session: AccountStoredSession) throws {
        savedSession = session
        do { try credentials.save(session) } catch {
            settings.save(session.configuration, allowsSessionRestore: false)
            throw AccountIssue.secureStorage
        }
        settings.save(session.configuration, allowsSessionRestore: true)
    }

    private func accept(_ identity: AccountIdentity, credentials: AccountCredentials,
                        configuration: AccountServiceConfiguration) throws {
        try persist(AccountStoredSession(configuration: configuration, credentials: credentials, identity: identity))
        issue = nil
        state = .signedIn(identity)
        scheduleRefresh(credentials)
    }

    private func handleSignInFailure(_ error: Error) {
        let failure = error as? AccountIssue ?? (error is CancellationError ? .cancelled : .invalidResponse)
        if savedSession != nil { handleSessionFailure(failure); return }
        issue = failure
        state = codePrompt == nil ? .signedOut : .awaitingCode
        if [.codeExpired, .codeConsumed, .tooManyAttempts].contains(failure) { expireChallenge(issue: failure) }
    }

    private func handleSessionFailure(_ error: Error) {
        let failure = error as? AccountIssue ?? (error is CancellationError ? .cancelled : .invalidResponse)
        issue = failure
        refreshTimer?.cancel()
        if [.credentialsInvalid, .identityChanged].contains(failure) {
            savedSession = nil
            if let configuration {
                settings.save(configuration, allowsSessionRestore: false)
                do { try credentials.clear(configuration: configuration) } catch { issue = .secureStorage }
            }
            state = .credentialsInvalid
        } else {
            state = .offline(savedSession?.identity)
        }
    }

    private func scheduleRefresh(_ credentials: AccountCredentials) {
        refreshTimer?.cancel()
        let ticket = generation
        let delay = max(1, credentials.expiresAt.timeIntervalSinceNow - 60)
        refreshTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, ticket == generation else { return }
            _ = try? await confirmedIdentity(forceRefresh: true)
        }
    }

    private func scheduleChallengeExpiry(_ challenge: AccountOTPChallenge, ticket: UInt64) {
        challengeTimer?.cancel()
        challengeTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, challenge.expiresAt.timeIntervalSinceNow))) } catch { return }
            guard let self, ticket == generation else { return }
            expireChallenge()
        }
    }

    private func expireChallenge(issue: AccountIssue = .codeExpired) {
        codePrompt?.isExpired = true
        self.issue = issue
    }

    private func check(_ ticket: UInt64) throws {
        try Task.checkCancellation()
        guard ticket == generation else { throw AccountIssue.cancelled }
    }

    private func clearMemory() {
        savedSession = nil
        challenge = nil
        codePrompt = nil
    }

    private func retireWork() {
        generation &+= 1
        operation?.cancel()
        operation = nil
        recovery?.cancel()
        recovery = nil
        recoveryID = nil
        refreshTimer?.cancel()
        refreshTimer = nil
        challengeTimer?.cancel()
        challengeTimer = nil
    }
}
