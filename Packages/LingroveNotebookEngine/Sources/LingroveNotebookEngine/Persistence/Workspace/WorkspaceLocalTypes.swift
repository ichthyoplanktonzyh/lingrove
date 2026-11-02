import Foundation

public struct Workspace: Codable, Hashable, Sendable {
    public let workspaceId: String
    public let name: String
    public let createdAt: String

    public init(workspaceId: String, name: String, createdAt: String) {
        self.workspaceId = workspaceId
        self.name = name
        self.createdAt = createdAt
    }
}

public struct UserSettings: Codable, Hashable, Sendable {
    public let userId: String
    public let workspaceId: String
    public let email: String?
    public let locale: String
    public let createdAt: String

    public init(userId: String, workspaceId: String, email: String?, locale: String, createdAt: String) {
        self.userId = userId
        self.workspaceId = workspaceId
        self.email = email
        self.locale = locale
        self.createdAt = createdAt
    }
}

public struct BootstrapSnapshotRefreshOutcome: Hashable, Sendable {
    public let didChange: Bool
    public let workspaceChanged: Bool
    public let cardsChanged: Bool

    public init(didChange: Bool, workspaceChanged: Bool, cardsChanged: Bool) {
        self.didChange = didChange
        self.workspaceChanged = workspaceChanged
        self.cardsChanged = cardsChanged
    }
}

public struct AppBootstrapSnapshot: Hashable, Sendable {
    public let workspace: Workspace
    public let userSettings: UserSettings
    public let schedulerSettings: WorkspaceSchedulerSettings
    public let cloudSettings: CloudSettings

    public init(workspace: Workspace, userSettings: UserSettings, schedulerSettings: WorkspaceSchedulerSettings, cloudSettings: CloudSettings) {
        self.workspace = workspace
        self.userSettings = userSettings
        self.schedulerSettings = schedulerSettings
        self.cloudSettings = cloudSettings
    }
}
