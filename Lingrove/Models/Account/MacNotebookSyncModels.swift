import Foundation
import LingroveCloud

/// Safe account snapshots cross only the native session/controller seam. Tokens stay inside the
/// SDK capability. The session facade owns each value until its next atomic publication.
nonisolated struct MacAccountObservation: Equatable {
    var configuration: AccountServiceConfiguration?
    var state: AccountSessionState = .unconfigured
    var retainedIdentity: AccountIdentity?
    var generation: UInt64 = 0
}

/// Independent lanes prevent a successful corpus pass from claiming the review endpoint worked.
/// The app-owned sync controller publishes these small values; Settings never reads SQL or tokens.
nonisolated enum MacNotebookSyncStatus: Equatable {
    case local, needsWorkspace, needsOwnership, ready, working, synchronized, pending
    case offline, unavailable, forbidden, failed, conflict, rejected, cancelled
}

/// This is authorization metadata, not another notebook database. Exact endpoint + owner bytes
/// scope the user's explicit workspace/sync choice, and disabling sync survives process restart.
nonisolated struct MacNotebookSyncConsent: Codable, Equatable {
    let endpoint: String
    let owner: Data
    var workspaceID: String
    var enabled: Bool

    func matches(_ configuration: AccountServiceConfiguration, identity: AccountIdentity) -> Bool {
        endpoint == configuration.apiBaseURL.absoluteString && owner == Data(identity.userID.utf8)
    }
}
