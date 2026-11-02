import Foundation

/// Account shells and proposals borrow the corpus connection; login alone never copies content.
extension LingroveNotebookEngine {
    public func updateCloudSettings(
        cloudState: CloudAccountState,
        linkedUserId: String?,
        linkedWorkspaceId: String?,
        activeWorkspaceId: String?,
        linkedEmail: String?
    ) throws {
        try self.workspaceSettingsStore.updateCloudSettings(
            cloudState: cloudState,
            linkedUserId: linkedUserId,
            linkedWorkspaceId: linkedWorkspaceId,
            activeWorkspaceId: activeWorkspaceId,
            linkedEmail: linkedEmail
        )
    }

    public func updateWorkspaceName(workspaceId: String, name: String) throws -> Workspace {
        try self.workspaceSettingsStore.updateWorkspaceName(workspaceId: workspaceId, name: name)
    }

    public func switchActiveWorkspace(
        workspace: CloudWorkspaceSummary,
        linkedSession: CloudLinkedSession
    ) throws {
        let shellStore = self.makeWorkspaceShellStore()
        try self.core.inTransaction {
            try shellStore.ensureLinkedWorkspaceShell(workspace: workspace)
            try LingroveNotebookAccountStore(core: core).bindInTransaction(linkedSession)
            try shellStore.ensureSyncStateExists(workspaceId: workspace.workspaceId)
            try shellStore.updateAccountWorkspaceReference(workspaceId: workspace.workspaceId)
            try self.workspaceSettingsStore.updateCloudSettings(
                cloudState: .linked,
                linkedUserId: linkedSession.userId,
                linkedWorkspaceId: workspace.workspaceId,
                activeWorkspaceId: workspace.workspaceId,
                linkedEmail: linkedSession.email
            )
        }
    }

    public func preserveNotebookWorkspaceForLink(source: String, account: CloudLinkedSession,
                                                  workspace: CloudWorkspaceSummary? = nil,
                                                  guestCardsAlreadyMerged: Bool = false,
                                                  inheritLocalScheduler: Bool = false) throws -> Bool {
        guard try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_state WHERE workspace_id IN (?,?) AND revision>0",
            values: [.text(source), .text(account.workspaceId)]) > 0 else { return false }
        let shell = makeWorkspaceShellStore()
        try core.inTransaction {
            let owners = LingroveNotebookAccountStore(core: core)
            try owners.captureActiveScopeInTransaction()
            // Capture the source's local/guest status before new settings adopt
            // the target. Existing linked scopes are never offered for transfer.
            let sourceWorkspace = try workspaceSettingsStore.loadWorkspace()
            guard sourceWorkspace.workspaceId == source else { throw LingroveNotebookAccountError.ownerMismatch }
            let newTarget = try core.scalarInt(sql: "SELECT count(*) FROM workspaces WHERE workspace_id=?", values: [.text(account.workspaceId)]) == 0
            try shell.ensureLinkedWorkspaceShell(workspace: workspace ?? .init(workspaceId: account.workspaceId,
                name: sourceWorkspace.name, createdAt: sourceWorkspace.createdAt, isSelected: true))
            try owners.bindInTransaction(account)
            if inheritLocalScheduler && newTarget {
                // Retain the existing empty-workspace link policy. Moving a
                // notebook through an explicit handoff must not silently reset
                // the source's FSRS preferences to a new shell's defaults.
                let original = try workspaceSettingsStore.loadWorkspaceSchedulerSettings(workspaceId: source)
                let installation = try workspaceSettingsStore.loadCloudSettings().installationId
                let operation = UUID().uuidString.lowercased(), now = nowIsoTimestamp()
                let copied = try workspaceSettingsStore.updateWorkspaceSchedulerSettings(workspaceId: account.workspaceId,
                    desiredRetention: original.desiredRetention, learningStepsMinutes: original.learningStepsMinutes,
                    relearningStepsMinutes: original.relearningStepsMinutes, maximumIntervalDays: original.maximumIntervalDays,
                    enableFuzz: original.enableFuzz, installationId: installation, operationId: operation, now: now)
                try outboxStore.enqueueWorkspaceSchedulerSettingsUpsertOperation(workspaceId: account.workspaceId,
                    installationId: installation, operationId: operation, clientUpdatedAt: now, settings: copied)
            }
            try owners.proposeInTransaction(source: source, account: account, guestCardsAlreadyMerged: guestCardsAlreadyMerged)
            try shell.ensureSyncStateExists(workspaceId: account.workspaceId)
            try shell.updateAccountWorkspaceReference(workspaceId: account.workspaceId)
            try workspaceSettingsStore.updateCloudSettings(cloudState: account.authorization.isGuest ? .guest : .linked,
                linkedUserId: account.userId, linkedWorkspaceId: account.workspaceId, activeWorkspaceId: account.workspaceId, linkedEmail: account.email)
        }
        return true
    }

    private func makeWorkspaceShellStore() -> WorkspaceShellStore {
        WorkspaceShellStore(
            core: self.core,
            workspaceSettingsStore: self.workspaceSettingsStore
        )
    }
}
