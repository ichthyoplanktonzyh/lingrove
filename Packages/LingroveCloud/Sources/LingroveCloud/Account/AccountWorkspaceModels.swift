import Foundation

/// Server-owned workspace metadata is separate from local ownership and sync consent. Hosts may
/// display these values after login, but must require an explicit choice before binding storage.
public nonisolated struct AccountWorkspace: Codable, Equatable, Identifiable, Sendable {
    public let workspaceId: String
    public let name: String
    public let createdAt: String
    public let isSelected: Bool
    public let isVisible: Bool
    public var id: String { workspaceId }

    public init(workspaceId: String, name: String, createdAt: String, isSelected: Bool, isVisible: Bool = true) {
        self.workspaceId = workspaceId; self.name = name; self.createdAt = createdAt
        self.isSelected = isSelected; self.isVisible = isVisible
    }
    private enum CodingKeys: String, CodingKey { case workspaceId, name, createdAt, isSelected, isVisible }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(workspaceId: try fields.decode(String.self, forKey: .workspaceId),
            name: try fields.decode(String.self, forKey: .name), createdAt: try fields.decode(String.self, forKey: .createdAt),
            isSelected: try fields.decode(Bool.self, forKey: .isSelected),
            isVisible: try fields.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true)
    }
}

/// This reply was checked against the same authorization's `/me.userId`. A selected workspace in
/// the server profile remains informational: it does not select anything on this Mac.
public nonisolated struct AccountWorkspaceMetadata: Equatable, Sendable {
    public let identity: AccountIdentity
    public let selectedWorkspaceID: String?
    public let workspaces: [AccountWorkspace]
    public init(identity: AccountIdentity, selectedWorkspaceID: String?, workspaces: [AccountWorkspace]) {
        self.identity = identity; self.selectedWorkspaceID = selectedWorkspaceID; self.workspaces = workspaces
    }
}

/// The fixed FSRS wire value contains no Card/UI dependency. The host maps it into its existing
/// engine settings, including the service's clocks, rather than manufacturing local defaults.
public nonisolated struct AccountWorkspaceSchedulerSettings: Codable, Equatable, Sendable {
    public let algorithm: String
    public let desiredRetention: Double
    public let learningStepsMinutes: [Int]
    public let relearningStepsMinutes: [Int]
    public let maximumIntervalDays: Int
    public let enableFuzz: Bool
    public let clientUpdatedAt: String
    public let lastModifiedByReplicaId: String
    public let lastOperationId: String
    public let updatedAt: String

    public init(algorithm: String, desiredRetention: Double, learningStepsMinutes: [Int],
                relearningStepsMinutes: [Int], maximumIntervalDays: Int, enableFuzz: Bool,
                clientUpdatedAt: String, lastModifiedByReplicaId: String, lastOperationId: String, updatedAt: String) {
        self.algorithm = algorithm; self.desiredRetention = desiredRetention
        self.learningStepsMinutes = learningStepsMinutes; self.relearningStepsMinutes = relearningStepsMinutes
        self.maximumIntervalDays = maximumIntervalDays; self.enableFuzz = enableFuzz
        self.clientUpdatedAt = clientUpdatedAt; self.lastModifiedByReplicaId = lastModifiedByReplicaId
        self.lastOperationId = lastOperationId; self.updatedAt = updatedAt
    }
}

/// No backend messages or response content reach the UI. Authentication failure is kept distinct
/// so the app-owned AccountSession can refresh its own credentials exactly once.
public nonisolated enum AccountWorkspaceError: Error, Equatable, Sendable {
    case unavailable, forbidden, invalidResponse, network, authentication, identityChanged
}

@MainActor
/// The native lifecycle borrows one loader for the process. This is a read-only transport seam,
/// independent of SQL and UI, so another host can provide the same verified metadata contract.
public protocol AccountWorkspaceLoading: AnyObject {
    func metadata(authorization: AccountAuthorization) async throws -> AccountWorkspaceMetadata
    func schedulerSettings(workspaceID: UUID, installationID: UUID,
                           authorization: AccountAuthorization) async throws -> AccountWorkspaceSchedulerSettings
}
