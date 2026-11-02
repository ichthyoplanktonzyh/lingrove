import Foundation

public enum CloudAccountState: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case disconnected
    case linkingReady = "linking-ready"
    case guest
    case linked

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .disconnected:
            return String(
                localized: "cloud_account_state.disconnected.title",
                table: "Foundation",
                comment: "Cloud account state title for disconnected"
            )
        case .linkingReady:
            return String(
                localized: "cloud_account_state.linking_ready.title",
                table: "Foundation",
                comment: "Cloud account state title for linking ready"
            )
        case .guest:
            return String(
                localized: "cloud_account_state.guest.title",
                table: "Foundation",
                comment: "Cloud account state title for guest"
            )
        case .linked:
            return String(
                localized: "cloud_account_state.linked.title",
                table: "Foundation",
                comment: "Cloud account state title for linked"
            )
        }
    }
}

public enum CloudAuthorization: Hashable, Sendable {
    case bearer(String)
    case guest(String)

    public var headerValue: String {
        switch self {
        case .bearer(let token):
            return "Bearer \(token)"
        case .guest(let token):
            return "Guest \(token)"
        }
    }

    public var isGuest: Bool {
        switch self {
        case .guest:
            return true
        case .bearer:
            return false
        }
    }
}

public struct CloudLinkedSession: Hashable, Sendable {
    public let userId: String
    public let workspaceId: String
    public let email: String?
    public let configurationMode: CloudServiceConfigurationMode
    public let apiBaseUrl: String
    public let authorization: CloudAuthorization

    public var authorizationHeaderValue: String {
        self.authorization.headerValue
    }

    public var bearerToken: String {
        switch self.authorization {
        case .bearer(let token):
            return token
        case .guest:
            preconditionFailure("Bearer token is unavailable for guest cloud sessions")
        }
    }

    public init(userId: String, workspaceId: String, email: String?, configurationMode: CloudServiceConfigurationMode, apiBaseUrl: String, authorization: CloudAuthorization) {
        self.userId = userId
        self.workspaceId = workspaceId
        self.email = email
        self.configurationMode = configurationMode
        self.apiBaseUrl = apiBaseUrl
        self.authorization = authorization
    }
}

public struct CloudWorkspaceSummary: Codable, Identifiable, Hashable, Sendable {
    public let workspaceId: String
    public let name: String
    public let createdAt: String
    public let isSelected: Bool
    public let isVisible: Bool

    public init(workspaceId: String, name: String, createdAt: String, isSelected: Bool) {
        self.init(workspaceId: workspaceId, name: name, createdAt: createdAt, isSelected: isSelected, isVisible: true)
    }

    public init(workspaceId: String, name: String, createdAt: String, isSelected: Bool, isVisible: Bool) {
        self.workspaceId = workspaceId
        self.name = name
        self.createdAt = createdAt
        self.isSelected = isSelected
        self.isVisible = isVisible
    }

    private enum CodingKeys: String, CodingKey { case workspaceId, name, createdAt, isSelected, isVisible }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workspaceId: try fields.decode(String.self, forKey: .workspaceId),
            name: try fields.decode(String.self, forKey: .name),
            createdAt: try fields.decode(String.self, forKey: .createdAt),
            isSelected: try fields.decode(Bool.self, forKey: .isSelected),
            isVisible: try fields.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        )
    }

    public var id: String {
        workspaceId
    }
}

public enum CloudServiceConfigurationMode: String, Codable, Hashable, Sendable {
    case official
    case custom
}

public struct CloudSettings: Codable, Hashable, Sendable {
    public let installationId: String
    public let cloudState: CloudAccountState
    public let linkedUserId: String?
    public let linkedWorkspaceId: String?
    public let activeWorkspaceId: String?
    public let linkedEmail: String?
    public let onboardingCompleted: Bool
    public let updatedAt: String

    public init(installationId: String, cloudState: CloudAccountState, linkedUserId: String?, linkedWorkspaceId: String?, activeWorkspaceId: String?, linkedEmail: String?, onboardingCompleted: Bool, updatedAt: String) {
        self.installationId = installationId
        self.cloudState = cloudState
        self.linkedUserId = linkedUserId
        self.linkedWorkspaceId = linkedWorkspaceId
        self.activeWorkspaceId = activeWorkspaceId
        self.linkedEmail = linkedEmail
        self.onboardingCompleted = onboardingCompleted
        self.updatedAt = updatedAt
    }
}
