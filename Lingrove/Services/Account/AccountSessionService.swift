import Combine
import Foundation
import LingroveCloud

/// LingroveAppEnvironment owns one observable native facade for the process lifetime. Its shared
/// AccountSession owns all OTP, trusted identity, rotation and generation decisions; this facade
/// only publishes safe snapshots to existing Settings views. Keychain/configuration remain host
/// adapters, so extracting the core does not widen credential access or network authorization.
@MainActor
final class AccountSessionService: ObservableObject {
    @Published private(set) var configuration: AccountServiceConfiguration?
    @Published private(set) var state: AccountSessionState = .unconfigured
    @Published private(set) var codePrompt: AccountCodePrompt?
    @Published private(set) var issue: AccountIssue?
    /// One atomic safe projection is the lifecycle subscription seam. Publishing generation
    /// separately from state could briefly pair a new account boundary with an old UI value.
    @Published private(set) var observation = MacAccountObservation()
    /// `@Published` emits in willSet. Lifecycle consumers need the fully assigned facade before
    /// a synchronous logout fence runs, so this stream sends only after all safe fields commit.
    let observationChanges = PassthroughSubject<MacAccountObservation, Never>()
    private let session: AccountSession

    init(client: any AccountAuthenticating, credentials: any AccountCredentialStoring,
         settings: AccountConfigurationStore) {
        session = AccountSession(client: client, credentials: credentials, settings: settings)
        session.onChange = { [weak self] in self?.publish() }
        publish()
    }

    func start() { session.start() }
    func shutdown() { session.shutdown() }
    @discardableResult func configure(api: String, auth: String) -> Bool { session.configure(api: api, auth: auth) }
    @discardableResult func removeConfiguration() -> Bool { session.removeConfiguration() }
    func requestCode(email: String) { session.requestCode(email: email) }
    func resendCode() { session.resendCode() }
    func submitCode(_ code: String) { session.submitCode(code) }
    func cancelSignIn() { session.cancelSignIn() }
    func signOut() { session.signOut() }
    func retrySession() { session.retrySession() }
    func resumeIfNeeded() { session.resumeIfNeeded() }
    func confirmedIdentity(recheck: Bool = false, forceRefresh: Bool = false) async throws -> AccountIdentity {
        try await session.confirmedIdentity(recheck: recheck, forceRefresh: forceRefresh)
    }
    func authorization(forceRefresh: Bool = false) async throws -> AccountAuthorization {
        try await session.authorization(forceRefresh: forceRefresh)
    }
    private func publish() {
        observation = MacAccountObservation(configuration: session.configuration, state: session.state,
            retainedIdentity: session.retainedIdentity, generation: session.generation)
        configuration = session.configuration; state = session.state
        codePrompt = session.codePrompt; issue = session.issue
        observationChanges.send(observation)
    }
}
