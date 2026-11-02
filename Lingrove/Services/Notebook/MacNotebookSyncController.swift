import Combine
import Foundation
import LingroveCloud
import LingroveNotebook
import LingroveNotebookCloud
import LingroveNotebookEngine
import LingroveNotebookSync

/// LingroveAppEnvironment owns this controller beside its one repository and account service.
/// It owns consent, trusted workspace selection and task lifetimes; the shared coordinator owns
/// networking and the shared engine owns every durable operation. Windows only observe/call it.
/// No subscription, service request, account adoption or upload starts in the initializer.
@MainActor
final class MacNotebookSyncController: ObservableObject {
    @Published private(set) var workspaces: [AccountWorkspace] = []
    @Published private(set) var selectedWorkspace: AccountWorkspace?
    @Published private(set) var ownershipProposal: LingroveNotebookOwnershipProposal?
    @Published private(set) var firstConnection: LingroveNotebookFirstConnection?
    @Published private(set) var enabled = false
    @Published private(set) var isChoosingWorkspace = false
    @Published private(set) var isLoadingWorkspaces = false
    @Published private(set) var corpusStatus: MacNotebookSyncStatus = .local
    @Published private(set) var mediaStatus: MacNotebookSyncStatus = .local
    @Published private(set) var reviewStatus: MacNotebookSyncStatus = .local
    @Published private(set) var workspaceStatus: MacNotebookSyncStatus = .needsWorkspace
    @Published private(set) var schedulerStatus: MacNotebookSyncStatus = .local
    @Published private(set) var canAccessWorkspaces = false

    let repository: MacNotebookRepository
    private let account: AccountSessionService
    private let workspaceClient: any AccountWorkspaceLoading
    private let consentStore: MacNotebookSyncConsentStore
    private let coordinator: NotebookSyncCoordinator
    /// The coordinator and all media controls share this one registry. A second instance would
    /// let a cancelled UI transfer keep running in the background under a different owner.
    private let transfers: NotebookMediaTransfers
    private var subscriptions = Set<AnyCancellable>()
    private var metadataTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var metadataTicket = UUID()
    private var scopeTicket = UUID()
    private var observedAccount: MacAccountObservation?
    private var metadataAccount: MacAccountObservation?
    private var publishingRepository = false
    private var started = false

    init(repository: MacNotebookRepository, account: AccountSessionService,
         workspaceClient: (any AccountWorkspaceLoading)? = nil,
         consentStore: MacNotebookSyncConsentStore? = nil,
         transport: NotebookHTTPTransport? = nil, mediaTransport: NotebookMediaTransport? = nil) {
        self.repository = repository; self.account = account
        // Default arguments are evaluated outside the initializer's actor in Swift 5 mode.
        // Construct actor-isolated dependencies here, after entering the app's main actor.
        self.workspaceClient = workspaceClient ?? AccountWorkspaceClient()
        self.consentStore = consentStore ?? MacNotebookSyncConsentStore()
        let transfers = NotebookMediaTransfers()
        self.transfers = transfers
        coordinator = NotebookSyncCoordinator(storage: repository.cloudStorage, mediaStorage: repository.cloudStorage,
            reviewStorage: repository.cloudStorage, transport: transport ?? .init(),
            mediaTransport: mediaTransport ?? .init(), transfers: transfers)
    }

    /// The app delegate starts/stops subscriptions once. Neither Settings appearance nor a view
    /// cancellation can stop the shared flight. Startup trusts saved consent only for its exact
    /// endpoint/owner and never transfers a newly-created local library without another decision.
    func start() {
        guard !started else { return }
        started = true
        account.observationChanges.removeDuplicates().sink { [weak self] value in self?.accountChanged(value) }
            .store(in: &subscriptions)
        repository.$changeSequence.dropFirst().sink { [weak self] _ in self?.repositoryChanged() }
            .store(in: &subscriptions)
        accountChanged(account.observation)
    }

    func shutdown() {
        guard started else { return }
        started = false
        subscriptions.removeAll()
        cancelMetadata()
        selectionTask?.cancel(); selectionTask = nil
        stopNetwork(advanceGeneration: true)
        observedAccount = nil
        metadataAccount = nil
        workspaces = []; selectedWorkspace = nil; ownershipProposal = nil; firstConnection = nil
        enabled = false; canAccessWorkspaces = false
    }

    /// Only metadata is fetched after login; no workspace or corpus is selected by `/me` itself.
    func refreshWorkspaces() {
        guard started, account.observation.retainedIdentity != nil,
              case .signedIn = account.observation.state else { return }
        cancelMetadata()
        let ticket = metadataTicket
        isLoadingWorkspaces = true
        metadataTask = Task { [weak self] in
            guard let self else { return }
            defer { if ticket == metadataTicket { isLoadingWorkspaces = false; metadataTask = nil } }
            do {
                let (metadata, authorization) = try await authorized { authorization in
                    try await self.workspaceClient.metadata(authorization: authorization)
                }
                try check(authorization)
                guard ticket == metadataTicket,
                      metadata.identity.userID.utf8.elementsEqual(authorization.identity.userID.utf8) else { throw CancellationError() }
                workspaces = metadata.workspaces
                metadataAccount = account.observation
                workspaceStatus = .ready
                if selectedWorkspace == nil,
                   let saved = consentStore.consent(configuration: authorization.configuration, identity: authorization.identity),
                   let workspace = workspaces.first(where: { $0.id == saved.workspaceID }) {
                    chooseWorkspace(workspace.id, restoring: true)
                } else if let selectedWorkspace, !workspaces.contains(where: { $0.id == selectedWorkspace.id }) {
                    // Revoked visibility cannot leave a previously authorized timer running.
                    disconnectWorkspace()
                    workspaceStatus = .forbidden
                } else if enabled {
                    synchronize()
                }
            } catch {
                guard ticket == metadataTicket, !Task.isCancelled else { return }
                workspaceStatus = status(error)
            }
        }
    }

    func chooseWorkspace(_ id: String) { chooseWorkspace(id, restoring: false) }

    private func chooseWorkspace(_ id: String, restoring: Bool) {
        guard started, !isChoosingWorkspace, let workspace = workspaces.first(where: { $0.id == id }),
              let metadataAccount, metadataAccount.generation == account.observation.generation,
              metadataAccount.configuration == account.observation.configuration,
              case .signedIn = account.observation.state else { return }
        selectionTask?.cancel()
        stopNetwork(advanceGeneration: true)
        let ticket = scopeTicket
        isChoosingWorkspace = true
        selectionTask = Task { [weak self] in
            guard let self else { return }
            var didConnect = false
            defer {
                if ticket == scopeTicket {
                    isChoosingWorkspace = false; selectionTask = nil
                    if didConnect, enabled { synchronize() }
                }
            }
            do {
                let authorization = try await account.authorization()
                try check(authorization, ticket: ticket)
                let source = try repository.snapshot()
                guard let workspaceID = UUID(uuidString: id) else {
                    throw AccountWorkspaceError.invalidResponse
                }
                let installationID = try repository.engine.macNotebookInstallationID(workspaceID: id,
                    owner: authorization.identity.userID, endpoint: authorization.configuration.apiBaseURL.absoluteString)
                // First activation waits for the actual workspace settings. A fresh shell's
                // timestamped defaults must never silently replace a phone's FSRS preferences.
                schedulerStatus = .working
                let (settings, finalAuthorization) = try await authorized { authorization in
                    try await self.workspaceClient.schedulerSettings(workspaceID: workspaceID,
                        installationID: installationID, authorization: authorization)
                }
                try check(finalAuthorization, ticket: ticket)
                _ = try repository.engine.connectMacNotebookWorkspace(workspace: workspace.engineWorkspace,
                    session: finalAuthorization.linkedSession(workspaceID: id), scheduler: settings.engineSettings, basedOn: source)
                selectedWorkspace = workspace
                let previous = consentStore.consent(configuration: finalAuthorization.configuration, identity: finalAuthorization.identity)
                enabled = restoring ? (previous?.enabled ?? false) : false
                consentStore.save(.init(endpoint: finalAuthorization.configuration.apiBaseURL.absoluteString,
                    owner: Data(finalAuthorization.identity.userID.utf8), workspaceID: id, enabled: enabled))
                schedulerStatus = .synchronized
                workspaceStatus = .ready
                try reloadOwnership()
                firstConnection = try repository.engine.loadMacNotebookFirstConnection(scope: repository.snapshot())
                if firstConnection?.completed == true { firstConnection = nil }
                corpusStatus = ownershipProposal?.status == "pending" ? .needsOwnership : .ready
                mediaStatus = .ready; reviewStatus = .ready
                publishRepository()
                didConnect = true
            } catch {
                guard ticket == scopeTicket, !Task.isCancelled else { return }
                schedulerStatus = status(error); workspaceStatus = status(error)
                // A failed new selection leaves the prior local scope usable and sends no corpus.
            }
        }
    }

    /// A view supplies the proposal it actually displayed. Borrowing the latest property here
    /// would silently transfer an old conflict choice onto a newer revision/account generation.
    func resolveLocalCorpus(accept: Bool, choices: [Int: VocabularyWireConflictSelection.Choice] = [:],
                            expected: LingroveNotebookOwnershipProposal? = nil) {
        guard let proposal = expected ?? ownershipProposal, proposal.status != "merged" else { return }
        do {
            _ = try LingroveNotebookAccountStore(core: repository.engine.core).resolve(proposal, merge: accept, choices: choices)
            try reloadOwnership()
            corpusStatus = .ready
            publishRepository()
            if enabled { synchronize() }
        } catch { corpusStatus = .conflict; try? reloadOwnership() }
    }

    func resolveFirstConnection(combine: Bool, expected: LingroveNotebookFirstConnection? = nil) {
        guard let connection = expected ?? firstConnection, !connection.completed else { return }
        do {
            try LingroveNotebookAccountStore(core: repository.engine.core).resolveFirst(connection, merge: combine)
            firstConnection = nil
            corpusStatus = .pending
            coordinator.requestRetry()
            publishRepository()
            synchronize()
        } catch { corpusStatus = .conflict }
    }

    /// Consent is separate from login, workspace choice and local adoption. Turning it off revokes
    /// both network tasks and their durable generation, retaining every saved account row on disk.
    func setSynchronizationEnabled(_ value: Bool) {
        guard !isChoosingWorkspace, let workspace = selectedWorkspace, let configuration = account.configuration,
              let identity = account.observation.retainedIdentity else { return }
        if value, ownershipProposal?.status == "pending" { return }
        enabled = value
        consentStore.save(.init(endpoint: configuration.apiBaseURL.absoluteString,
            owner: Data(identity.userID.utf8), workspaceID: workspace.id, enabled: value))
        if value {
            synchronize()
        } else {
            stopNetwork(advanceGeneration: true)
            corpusStatus = .cancelled; mediaStatus = .cancelled; reviewStatus = .cancelled
        }
    }

    func retry() {
        if case .offline = account.observation.state { account.retrySession(); return }
        guard enabled, selectedWorkspace != nil else { refreshWorkspaces(); return }
        do {
            coordinator.requestRetry(try repository.cloudStorage.captureRetry(resumeCancelledUploads: true))
        } catch { corpusStatus = .failed; return }
        synchronize()
    }

    /// Cancelling revokes the ongoing automatic sync authorization too, so reopening a window or
    /// restarting cannot resume a user-cancelled transfer. Re-enable is another explicit action.
    func cancel() { setSynchronizationEnabled(false) }

    private func accountChanged(_ value: MacAccountObservation) {
        guard started else { return }
        let previous = observedAccount
        observedAccount = value
        if case .signedIn(let identity) = value.state {
            canAccessWorkspaces = value.retainedIdentity?.userID.utf8.elementsEqual(identity.userID.utf8) == true
        } else { canAccessWorkspaces = false }
        if let previous, previous.generation != value.generation || previous.configuration != value.configuration {
            cancelMetadata()
            selectionTask?.cancel(); selectionTask = nil; isChoosingWorkspace = false
            stopNetwork(advanceGeneration: true)
            isolateAccount()
            clearAccountPresentation()
            // `retireWork` publishes the new generation before clearing the old account state.
            // Revoke synchronously, then wait for the following complete state publication; an
            // old signed-in projection must not schedule fresh authorization after logout.
            return
        }
        switch value.state {
        case .signedIn(let identity):
            guard value.retainedIdentity?.userID.utf8.elementsEqual(identity.userID.utf8) == true else { return }
            isolateUnlessOwned(by: identity, configuration: value.configuration)
            if metadataAccount?.generation != value.generation || metadataAccount?.configuration != value.configuration {
                refreshWorkspaces()
            } else {
                workspaceStatus = .ready
                if enabled { synchronize() }
            }
        case .offline(let identity):
            isolateUnlessOwned(by: identity, configuration: value.configuration)
            stopNetwork(advanceGeneration: false)
            corpusStatus = .offline; mediaStatus = .offline; reviewStatus = .offline
            workspaceStatus = .offline; schedulerStatus = .offline
        case .working(.refreshing), .working(.restoring):
            isolateUnlessOwned(by: value.retainedIdentity, configuration: value.configuration)
        default:
            cancelMetadata()
            stopNetwork(advanceGeneration: false)
            isolateAccount()
            clearAccountPresentation()
            corpusStatus = .local; mediaStatus = .local; reviewStatus = .local
        }
    }

    private func clearAccountPresentation() {
        workspaces = []; metadataAccount = nil; selectedWorkspace = nil
        enabled = false; ownershipProposal = nil; firstConnection = nil; canAccessWorkspaces = false
        if workspaceStatus != .failed { workspaceStatus = .needsWorkspace }
        schedulerStatus = .local
    }

    private func isolateUnlessOwned(by identity: AccountIdentity?, configuration: AccountServiceConfiguration?) {
        do {
            let current = try repository.engine.workspaceSettingsStore.loadCloudSettings()
            guard current.linkedUserId != nil else { return }
            guard let identity, let configuration, let saved = consentStore.consent(configuration: configuration, identity: identity),
                  current.linkedUserId?.utf8.elementsEqual(identity.userID.utf8) == true,
                  current.activeWorkspaceId == saved.workspaceID else { isolateAccount(); return }
        } catch { workspaceStatus = .failed }
    }

    private func isolateAccount() {
        do {
            guard try repository.engine.workspaceSettingsStore.loadCloudSettings().linkedUserId != nil else { return }
            try LingroveNotebookAccountStore(core: repository.engine.core).isolateForSignOut()
            publishRepository()
        } catch { workspaceStatus = .failed }
    }

    private func disconnectWorkspace() {
        stopNetwork(advanceGeneration: true)
        isolateAccount()
        selectedWorkspace = nil; ownershipProposal = nil; firstConnection = nil; enabled = false
    }

    private func repositoryChanged() {
        guard !publishingRepository, selectedWorkspace != nil else { return }
        do { try reloadOwnership() } catch { corpusStatus = .failed }
        guard enabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.synchronize()
        }
    }

    private func reloadOwnership() throws {
        guard let workspace = selectedWorkspace else { ownershipProposal = nil; return }
        ownershipProposal = try LingroveNotebookAccountStore(core: repository.engine.core).proposal(workspaceID: workspace.id)
    }

    private func cancelMetadata() {
        metadataTicket = UUID(); metadataTask?.cancel(); metadataTask = nil; isLoadingWorkspaces = false
    }

    private func stopNetwork(advanceGeneration: Bool) {
        scopeTicket = UUID()
        // Every caller which changes the ticket also retires the task/UI that held it. A failed
        // credential refresh may enter this method from inside workspace selection itself; its
        // ticket-guarded defer can no longer clear the spinner after this point.
        selectionTask?.cancel(); selectionTask = nil; isChoosingWorkspace = false
        syncTask?.cancel(); syncTask = nil; pollTask?.cancel(); pollTask = nil
        debounceTask?.cancel(); debounceTask = nil
        coordinator.cancel()
        if advanceGeneration {
            do {
                try repository.engine.retireMacNotebookScope(expectedGeneration: repository.snapshot().generation)
                try reloadOwnership()
                firstConnection = try repository.engine.loadMacNotebookFirstConnection(scope: repository.snapshot())
                if firstConnection?.completed == true { firstConnection = nil }
                publishRepository()
            } catch { workspaceStatus = .failed }
        }
    }

    private func check(_ authorization: AccountAuthorization, ticket: UUID? = nil) throws {
        try Task.checkCancellation()
        guard started, authorization.generation == account.observation.generation,
              authorization.configuration == account.observation.configuration,
              account.observation.retainedIdentity?.userID.utf8.elementsEqual(authorization.identity.userID.utf8) == true,
              ticket.map({ $0 == scopeTicket }) ?? true else { throw CancellationError() }
    }

    private func publishRepository() {
        publishingRepository = true
        repository.publishChange()
        publishingRepository = false
    }
}

private extension AccountWorkspace {
    var engineWorkspace: CloudWorkspaceSummary {
        .init(workspaceId: id, name: name, createdAt: createdAt, isSelected: isSelected, isVisible: isVisible)
    }
}
private extension AccountAuthorization {
    func linkedSession(workspaceID: String) -> CloudLinkedSession {
        .init(userId: identity.userID, workspaceId: workspaceID, email: identity.email, configurationMode: .custom,
            apiBaseUrl: configuration.apiBaseURL.absoluteString, authorization: .bearer(idToken))
    }
}
extension AccountWorkspaceSchedulerSettings {
    var engineSettings: WorkspaceSchedulerSettings {
        .init(algorithm: algorithm, desiredRetention: desiredRetention, learningStepsMinutes: learningStepsMinutes,
            relearningStepsMinutes: relearningStepsMinutes, maximumIntervalDays: maximumIntervalDays, enableFuzz: enableFuzz,
            clientUpdatedAt: clientUpdatedAt, lastModifiedByReplicaId: lastModifiedByReplicaId,
            lastOperationId: lastOperationId, updatedAt: updatedAt)
    }
}

private extension MacNotebookSyncController {
    func synchronize() {
        guard started, enabled, !isChoosingWorkspace, syncTask == nil, let workspace = selectedWorkspace,
              ownershipProposal?.status != "pending", firstConnection == nil,
              case .signedIn = account.observation.state else { return }
        pollTask?.cancel(); pollTask = nil
        let ticket = scopeTicket
        corpusStatus = .working; mediaStatus = .working; reviewStatus = .working
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if ticket == scopeTicket {
                    syncTask = nil
                    schedulePoll()
                }
            }
            do {
                guard let workspaceID = UUID(uuidString: workspace.id) else { throw AccountWorkspaceError.invalidResponse }
                let initial = try repository.snapshot()
                let installation = try repository.engine.workspaceSettingsStore.loadCloudSettings().installationId
                guard let installationID = UUID(uuidString: installation) else { throw AccountWorkspaceError.invalidResponse }
                let (settings, authorization) = try await authorized { authorization in
                    try await self.workspaceClient.schedulerSettings(workspaceID: workspaceID,
                        installationID: installationID, authorization: authorization)
                }
                try check(authorization, ticket: ticket)
                try repository.engine.applyMacNotebookSchedulerSettings(settings.engineSettings, scope: initial)
                schedulerStatus = .synchronized
                // Storage/network each re-check this same durable lifetime after every await.
                // A token refresh may replace credentials, but never changes the business owner.
                let (report, finalAuthorization) = try await authorized { authorization in
                    try await self.coordinator.synchronize(.init(userID: authorization.identity.userID,
                        workspaceID: workspaceID, apiBaseURL: authorization.configuration.apiBaseURL.absoluteString,
                        authorizationHeaderValue: "Bearer \(authorization.idToken)", isAutomation: false, isTestDistribution: false,
                        nativePlatform: .macos))
                }
                try check(finalAuthorization, ticket: ticket)
                try repository.cloudStorage.validate(report.binding)
                corpusStatus = status(report.status)
                reviewStatus = report.reviewStatus.map(status) ?? (report.status == .synchronized ? .pending : status(report.status))
                let scope = try repository.snapshot()
                firstConnection = try repository.engine.loadMacNotebookFirstConnection(scope: scope)
                if firstConnection?.completed == true { firstConnection = nil }
                mediaStatus = try currentMediaStatus(report: report)
                publishRepository()
            } catch {
                guard ticket == scopeTicket, !Task.isCancelled else { return }
                let failure = status(error)
                corpusStatus = failure; mediaStatus = failure; reviewStatus = failure
                if failure != .cancelled { schedulerStatus = failure }
                publishRepository()
            }
        }
    }

    func schedulePoll() {
        guard started, enabled, selectedWorkspace != nil, ownershipProposal?.status != "pending", firstConnection == nil else { return }
        pollTask?.cancel()
        // This bounded app-lifetime retry also notices remote edits while no window is open.
        // Network gates and frozen-body recovery remain inside the shared coordinator/storage.
        pollTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.synchronize()
        }
    }

    func currentMediaStatus(report: NotebookSyncReport) throws -> MacNotebookSyncStatus {
        let jobs = try LingroveNotebookMediaQueueStore(core: repository.engine.core).jobs(
            binding: .init(scope: report.binding.scope, generation: report.binding.generation))
        if jobs.contains(where: { $0.state == .cancelled }) { return .cancelled }
        if jobs.contains(where: { $0.state == .failed || $0.state == .missing }) { return .pending }
        if jobs.contains(where: { $0.state != .ready }) { return .pending }
        return report.status == .synchronized ? .synchronized : status(report.status)
    }

    /// A network 401 borrows the SDK's single-flight refresh once. There is no Keychain bypass or
    /// token parsing in this controller; the authorization still has to survive its original scope.
    func authorized<Value>(_ operation: (AccountAuthorization) async throws -> Value) async throws -> (Value, AccountAuthorization) {
        var authorization = try await account.authorization()
        try check(authorization)
        do {
            let value = try await operation(authorization)
            try check(authorization)
            return (value, authorization)
        } catch {
            let authenticationFailure: Bool
            if error as? AccountWorkspaceError == .authentication {
                authenticationFailure = true
            } else if case let NotebookNetworkError.http(code, _) = error {
                authenticationFailure = code == 401 || code == 410
            } else { authenticationFailure = false }
            guard authenticationFailure else { throw error }
            try check(authorization)
            authorization = try await account.authorization(forceRefresh: true)
            try check(authorization)
            let value = try await operation(authorization)
            try check(authorization)
            return (value, authorization)
        }
    }

    func status(_ error: any Error) -> MacNotebookSyncStatus {
        if error is CancellationError || error as? AccountIssue == .cancelled { return .cancelled }
        if error as? AccountWorkspaceError == .network || error as? AccountIssue == .network { return .offline }
        if error as? AccountWorkspaceError == .unavailable { return .unavailable }
        if error as? AccountWorkspaceError == .forbidden { return .forbidden }
        if error as? AccountWorkspaceError == .identityChanged || error as? AccountIssue == .identityChanged { return .forbidden }
        if error as? NotebookStorageError == .ownershipRequired { return .needsOwnership }
        return .failed
    }

    func status(_ value: NotebookSyncReport.Status) -> MacNotebookSyncStatus {
        switch value {
        case .synchronized: .synchronized
        case .pending: .pending
        case .unavailable: .unavailable
        case .offline: .offline
        case .conflict: .conflict
        case .rejected: .rejected
        case .cancelled: .cancelled
        case .failed: .failed
        case .ownershipRequired: .needsOwnership
        }
    }
}
