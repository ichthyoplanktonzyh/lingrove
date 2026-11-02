import Foundation
import LingroveNotebook
import LingroveNotebookSync

/// Native account lifecycle commands borrow the primary connection only for short transactions.
/// The Mac controller owns consent/tasks; this seam keeps scope CAS, first shell settings and the
/// existing ownership machinery atomic without introducing a second database or scheduler.
extension LingroveNotebookEngine {
    /// Before switching, settings bootstrap must borrow the target account's retained installation
    /// rather than registering a fresh local shell's ID and then connecting with a different ID.
    /// Reading it grants no adoption or network permission and never exposes a credential.
    public func macNotebookInstallationID(workspaceID: String, owner: String, endpoint: String) throws -> UUID {
        try core.inReadTransaction {
            let rows = try core.query(sql: """
                SELECT owner_user_id,api_base_url,installation_id FROM notebook_account_scopes WHERE workspace_id=?
                """,
                values: [.text(workspaceID)]) { row -> UUID? in
                guard let storedOwner = DatabaseCore.columnOptionalText(statement: row, index: 0) else { return nil }
                let storedEndpoint = DatabaseCore.columnText(statement: row, index: 1)
                guard storedOwner.utf8.elementsEqual(owner.utf8), storedEndpoint.isEmpty || storedEndpoint == endpoint,
                      let id = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 2)) else {
                    throw LingroveNotebookAccountError.ownerMismatch
                }
                return id
            }
            if let record = rows.first, let retained = record { return retained }
            guard let id = UUID(uuidString: try workspaceSettingsStore.loadCloudSettings().installationId) else {
                throw LingroveNotebookAccountError.ownerMismatch
            }
            return id
        }
    }

    /// Retires every old callback even when account/workspace values are unchanged. The token's
    /// shape and staging cleanup match the existing settings trigger; corpus/history/journals and
    /// remote cursors remain intact. The caller must supply the lifetime it intends to revoke.
    public func retireMacNotebookScope(expectedGeneration: String) throws {
        try core.inTransaction {
            guard try core.execute(sql: "DELETE FROM notebook_window_binding WHERE settings_id=1 AND generation=?",
                values: [.text(expectedGeneration)]) == 1 else { throw VocabularyError.editConflict }
            try core.execute(sql: """
                INSERT INTO notebook_window_binding(settings_id,generation) VALUES(1,lower(hex(randomblob(16))))
                """, values: [])
        }
    }

    /// An initial shell uses the server's settings verbatim, including clocks. Timestamped local
    /// defaults would otherwise beat an older custom remote setting under the existing LWW rule.
    /// Existing shells keep ordinary LWW semantics and every local corpus still needs a proposal.
    public func connectMacNotebookWorkspace(
        workspace: CloudWorkspaceSummary, session: CloudLinkedSession, scheduler: WorkspaceSchedulerSettings,
        basedOn source: LingroveNotebookSnapshot
    ) throws -> LingroveNotebookSnapshot {
        try core.inTransaction {
            try requireMacNotebookScope(source)
            let settings = workspaceSettingsStore
            let owners = LingroveNotebookAccountStore(core: core)
            let shell = WorkspaceShellStore(core: core, workspaceSettingsStore: settings)
            try owners.captureActiveScopeInTransaction()
            let isNew = try core.scalarInt(sql: "SELECT count(*) FROM workspaces WHERE workspace_id=?",
                values: [.text(workspace.workspaceId)]) == 0
            if isNew {
                try shell.insertWorkspaceFromLocalSettings(workspaceId: workspace.workspaceId, name: workspace.name,
                    createdAt: workspace.createdAt, settings: scheduler)
            } else {
                try shell.ensureLinkedWorkspaceShell(workspace: workspace)
                _ = try syncApplier.applySyncBootstrapEntry(workspaceId: workspace.workspaceId,
                    entry: .init(entityType: .workspaceSchedulerSettings, entityId: workspace.workspaceId,
                        action: .upsert, payload: .workspaceSchedulerSettings(scheduler)))
            }
            try owners.bindInTransaction(session)
            try owners.proposeInTransaction(source: source.workspaceId, account: session)
            try shell.ensureSyncStateExists(workspaceId: workspace.workspaceId)
            try shell.updateAccountWorkspaceReference(workspaceId: workspace.workspaceId)
            try settings.updateCloudSettings(cloudState: .linked, linkedUserId: session.userId,
                linkedWorkspaceId: workspace.workspaceId, activeWorkspaceId: workspace.workspaceId, linkedEmail: session.email)
            // `load` itself opens a transaction. Use its existing in-transaction header creation
            // here instead, so no nested BEGIN can partially commit a new account's shell.
            try core.execute(sql: """
                INSERT OR IGNORE INTO notebook_state(workspace_id,notebook_id,revision,has_templates,updated_at) VALUES(?,?,0,0,?)
                """,
                values: [.text(workspace.workspaceId), .text(UUID().uuidString), .text(nowIsoTimestamp())])
            return try lingroveNotebookStore.readSnapshot(workspaceId: workspace.workspaceId)
        }
    }

    public func applyMacNotebookSchedulerSettings(
        _ settings: WorkspaceSchedulerSettings, scope: LingroveNotebookSnapshot
    ) throws {
        try core.inTransaction {
            try requireMacNotebookScope(scope, compareRevision: false)
            _ = try syncApplier.applySyncBootstrapEntry(workspaceId: scope.workspaceId,
                entry: .init(entityType: .workspaceSchedulerSettings, entityId: scope.workspaceId,
                    action: .upsert, payload: .workspaceSchedulerSettings(settings)))
        }
    }

    /// The canonical first-connection store needs actual book/replica IDs. Its ownership-required
    /// report may contain only pre-connect placeholders, so load those IDs from its saved row under
    /// the same active generation instead of trusting a UI/network guess.
    public func loadMacNotebookFirstConnection(scope: LingroveNotebookSnapshot) throws -> LingroveNotebookFirstConnection? {
        try core.inReadTransaction {
            try requireMacNotebookScope(scope, compareRevision: false)
            let current = try workspaceSettingsStore.loadCloudSettings()
            guard let owner = current.linkedUserId, let workspace = UUID(uuidString: scope.workspaceId) else { return nil }
            let bindings = try core.query(sql: """
                SELECT owner_user_id,remote_notebook_id,replica_id FROM notebook_first_connections WHERE workspace_id=?
                """,
                values: [.text(scope.workspaceId)]) { row -> LingroveNotebookWindowBinding in
                guard DatabaseCore.columnText(statement: row, index: 0).utf8.elementsEqual(owner.utf8),
                      let book = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 1)),
                      let replica = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 2)) else {
                    throw LingroveNotebookAccountError.ownerMismatch
                }
                return .init(scope: .init(ownerUserID: owner, workspaceID: workspace, notebookID: book, replicaID: replica),
                    generation: scope.generation)
            }
            guard let binding = bindings.first else { return nil }
            return try LingroveNotebookAccountStore(core: core).firstConnectionInTransaction(binding: binding)
        }
    }

    private func requireMacNotebookScope(_ expected: LingroveNotebookSnapshot, compareRevision: Bool = true) throws {
        let settings = try workspaceSettingsStore.loadCloudSettings()
        guard settings.activeWorkspaceId == expected.workspaceId,
              try LingroveNotebookLocalScopeStore(core: core).generationInTransaction() == expected.generation else {
            throw VocabularyError.editConflict
        }
        let current = try lingroveNotebookStore.readSnapshot(workspaceId: expected.workspaceId)
        guard current.notebookId == expected.notebookId, !compareRevision || current.revision == expected.revision else {
            throw VocabularyError.editConflict
        }
    }
}
