import Foundation
import CryptoKit
import LingroveNotebook
import LingroveNotebookSync

public nonisolated enum LingroveNotebookAccountError: Error { case ownershipRequired, ownerMismatch, unavailableSource }

/// A transfer is offered only for the local/guest workspace which was active
/// during this authenticated link. Archived linked accounts never become
/// transfer candidates for the next person who signs in on the device.
public nonisolated struct LingroveNotebookOwnershipProposal: Identifiable, Sendable {
    public let id: String
    public let sourceWorkspaceID: String
    public let targetWorkspaceID: String
    public let ownerUserID: String
    public let generation: String
    public let source: LingroveNotebookSnapshot
    public let target: LingroveNotebookSnapshot
    public let status: String
    public let conflicts: [VocabularyWireConflictSelection]
    public let guestCardsAlreadyMerged: Bool
    public let canCombine: Bool

    public init(id: String, sourceWorkspaceID: String, targetWorkspaceID: String, ownerUserID: String, generation: String, source: LingroveNotebookSnapshot, target: LingroveNotebookSnapshot, status: String, conflicts: [VocabularyWireConflictSelection], guestCardsAlreadyMerged: Bool, canCombine: Bool) {
        self.id = id
        self.sourceWorkspaceID = sourceWorkspaceID
        self.targetWorkspaceID = targetWorkspaceID
        self.ownerUserID = ownerUserID
        self.generation = generation
        self.source = source
        self.target = target
        self.status = status
        self.conflicts = conflicts
        self.guestCardsAlreadyMerged = guestCardsAlreadyMerged
        self.canCombine = canCombine
    }
}

public nonisolated struct LingroveNotebookFirstConnection: Identifiable, Sendable {
    public let id: String
    public let binding: LingroveNotebookWindowBinding
    public let original: LingroveNotebookSnapshot
    public let remoteEntryCount: Int
    public let completed: Bool

    public init(id: String, binding: LingroveNotebookWindowBinding, original: LingroveNotebookSnapshot, remoteEntryCount: Int, completed: Bool) {
        self.id = id
        self.binding = binding
        self.original = original
        self.remoteEntryCount = remoteEntryCount
        self.completed = completed
    }
}

public nonisolated struct LingroveNotebookOwnershipSourceOption: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let entryCount: Int
    public let updatedAt: String

    public init(id: String, name: String, entryCount: Int, updatedAt: String) {
        self.id = id
        self.name = name
        self.entryCount = entryCount
        self.updatedAt = updatedAt
    }
}

/// Extends the existing workspace database with durable ownership and a small
/// explicit handoff. It neither rewrites frozen requests nor migrates byte
/// transfers. Original workspaces retain their exact rows and private history.
public nonisolated struct LingroveNotebookAccountStore {
    public let core: DatabaseCore
    /// Shared local-account visibility for workspace pickers and aggregate
    /// review history. Retained sources must not leak activity across sign-out.
    public static let visibleWorkspaceSQL = """
        SELECT active_workspace_id FROM app_local_settings WHERE settings_id=1
        UNION SELECT a.workspace_id FROM notebook_account_scopes a JOIN app_local_settings s ON s.settings_id=1
        WHERE s.linked_user_id IS NOT NULL AND a.owner_user_id=s.linked_user_id COLLATE BINARY
          AND (a.api_base_url='' OR a.api_base_url=(SELECT api_base_url FROM notebook_active_endpoint WHERE settings_id=1))
        """
    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_account_scopes (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
            owner_user_id TEXT,
            api_base_url TEXT NOT NULL DEFAULT '',
            installation_id TEXT NOT NULL,
            scope_kind TEXT NOT NULL CHECK(scope_kind IN ('local','guest','linked'))
        );
        CREATE TABLE IF NOT EXISTS notebook_active_endpoint (
            settings_id INTEGER PRIMARY KEY CHECK(settings_id=1), api_base_url TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS notebook_ownership_proposals (
            proposal_id TEXT PRIMARY KEY NOT NULL,
            source_workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE RESTRICT,
            target_workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
            owner_user_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','merged','separate')),
            guest_cards_merged INTEGER NOT NULL DEFAULT 0 CHECK(guest_cards_merged IN (0,1)),
            UNIQUE(target_workspace_id,owner_user_id,source_workspace_id)
        );
        CREATE TABLE IF NOT EXISTS notebook_first_connections (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            recovery_id TEXT NOT NULL,
            owner_user_id TEXT NOT NULL,
            remote_notebook_id TEXT NOT NULL,
            replica_id TEXT NOT NULL,
            local_notebook_id TEXT NOT NULL,
            local_revision INTEGER NOT NULL CHECK(local_revision>=0),
            original_json TEXT NOT NULL,
            original_sha256 TEXT NOT NULL CHECK(length(original_sha256)=64),
            remote_entries INTEGER NOT NULL CHECK(remote_entries>=0),
            decision TEXT NOT NULL DEFAULT 'pending' CHECK(decision IN ('pending','merge','remote')),
            authorized_generation TEXT,
            completed INTEGER NOT NULL DEFAULT 0 CHECK(completed IN (0,1))
        );
        CREATE TABLE IF NOT EXISTS notebook_account_private_remainders (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            local_notebook_id TEXT NOT NULL,
            private_json TEXT NOT NULL,
            private_sha256 TEXT NOT NULL CHECK(length(private_sha256)=64)
        );
        """
    public static let migrationSeedSQL = """
        INSERT OR IGNORE INTO notebook_account_scopes(workspace_id,owner_user_id,installation_id,scope_kind)
          SELECT w.workspace_id,
            COALESCE(r.owner_user_id,CASE WHEN w.workspace_id=s.active_workspace_id THEN s.linked_user_id ELSE NULL END),
            s.installation_id,
            CASE WHEN w.workspace_id=s.active_workspace_id AND s.cloud_state IN ('guest','linked') THEN s.cloud_state
              WHEN r.owner_user_id IS NOT NULL THEN 'linked' ELSE 'local' END
          FROM workspaces w CROSS JOIN app_local_settings s LEFT JOIN notebook_remote_state r ON r.workspace_id=w.workspace_id WHERE s.settings_id=1;
        """
    public static let resetSQL = "DROP TABLE IF EXISTS notebook_account_private_remainders;\nDROP TABLE IF EXISTS notebook_first_connections;\nDROP TABLE IF EXISTS notebook_ownership_proposals;\nDROP TABLE IF EXISTS notebook_active_endpoint;\nDROP TABLE IF EXISTS notebook_account_scopes;"

    public func privateRemainderInTransaction(workspaceID: String, localNotebookID: UUID, remoteNotebookID: UUID) throws -> VocabularyWirePrivateState? {
        try core.query(sql: "SELECT local_notebook_id,private_json,private_sha256 FROM notebook_account_private_remainders WHERE workspace_id=?",
            values: [.text(workspaceID)]) { row in
            let json = DatabaseCore.columnText(statement: row, index: 1)
            guard UUID(uuidString: DatabaseCore.columnText(statement: row, index: 0)) == localNotebookID,
                  digest(json) == DatabaseCore.columnText(statement: row, index: 2) else { throw LingroveNotebookSyncStoreError.corruptState }
            let state = try LingroveNotebookPrivateStateCodec.decode(json, notebookID: localNotebookID)
            return VocabularyWirePrivateState(notebookID: remoteNotebookID, reviews: state.reviews, explanations: state.explanations)
        }.first
    }

    public static func combinePrivate(_ first: VocabularyWirePrivateState?, _ second: VocabularyWirePrivateState?, notebookID: UUID) -> VocabularyWirePrivateState {
        var reviews = first?.reviews ?? [], explanations = first?.explanations ?? []
        for value in second?.reviews ?? [] where !reviews.contains(value) { reviews.append(value) }
        for value in second?.explanations ?? [] where !explanations.contains(value) { explanations.append(value) }
        return .init(notebookID: notebookID, reviews: reviews, explanations: explanations)
    }

    /// Called after a complete authorized bootstrap has been verified. Creating
    /// this local recovery record does not adopt a cursor or acknowledge intent.
    public func firstDecision(local: LingroveNotebookSnapshot, binding: LingroveNotebookWindowBinding,
                       remoteEntries: Int) throws -> Bool {
        let decision: Bool? = try core.inTransaction {
            try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
            let current = try LingroveNotebookStore(core: core).readSnapshot(workspaceId: local.workspaceId)
            guard current.revision == local.revision, current.notebookId == local.notebookId else { throw VocabularyError.editConflict }
            // A just-confirmed source handoff already states the user's intent
            // to combine content with this target account.
            if try core.scalarInt(sql: "SELECT EXISTS(SELECT 1 FROM notebook_ownership_proposals WHERE target_workspace_id=? AND owner_user_id=? AND status='merged')",
                values: [.text(local.workspaceId), .text(binding.scope.ownerUserID)]) != 0 { return true }
            if let existing = try firstConnectionInTransaction(binding: binding),
               existing.original.revision == current.revision {
                if let decision = try core.query(sql: "SELECT decision FROM notebook_first_connections WHERE workspace_id=? AND authorized_generation=?",
                    values: [.text(local.workspaceId), .text(binding.generation)], map: { DatabaseCore.columnText(statement: $0, index: 0) }).first,
                   decision != "pending" { return decision == "merge" }
                return nil
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let json = String(decoding: try encoder.encode(current.document), as: UTF8.self)
            try core.execute(sql: """
                INSERT INTO notebook_first_connections(workspace_id,recovery_id,owner_user_id,remote_notebook_id,replica_id,local_notebook_id,local_revision,original_json,original_sha256,remote_entries)
                VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(workspace_id) DO UPDATE SET recovery_id=excluded.recovery_id,
                  local_revision=excluded.local_revision,original_json=excluded.original_json,original_sha256=excluded.original_sha256,
                  remote_entries=excluded.remote_entries,decision='pending',authorized_generation=NULL
                """, values: [.text(local.workspaceId), .text(UUID().uuidString.lowercased()), .text(binding.scope.ownerUserID),
                    .text(binding.scope.notebookID.uuidString.lowercased()), .text(binding.scope.replicaID.uuidString.lowercased()),
                    .text(current.notebookId.uuidString), .integer(Int64(current.revision)), .text(json), .text(digest(json)), .integer(Int64(remoteEntries))])
            return nil
        }
        guard let decision else { throw LingroveNotebookAccountError.ownershipRequired }
        return decision
    }

    public func firstConnectionInTransaction(binding: LingroveNotebookWindowBinding) throws -> LingroveNotebookFirstConnection? {
        try LingroveNotebookWindowStore(core: core).checkBindingInTransaction(binding)
        return try core.query(sql: """
            SELECT recovery_id,owner_user_id,remote_notebook_id,replica_id,local_notebook_id,local_revision,original_json,original_sha256,remote_entries,completed
            FROM notebook_first_connections WHERE workspace_id=?
            """, values: [.text(binding.scope.workspaceID.uuidString.lowercased())]) { row in
            guard DatabaseCore.columnText(statement: row, index: 1).utf8.elementsEqual(binding.scope.ownerUserID.utf8),
                  UUID(uuidString: DatabaseCore.columnText(statement: row, index: 2)) == binding.scope.notebookID,
                  UUID(uuidString: DatabaseCore.columnText(statement: row, index: 3)) == binding.scope.replicaID,
                  let book = UUID(uuidString: DatabaseCore.columnText(statement: row, index: 4)) else { throw LingroveNotebookAccountError.ownerMismatch }
            let json = DatabaseCore.columnText(statement: row, index: 6)
            guard digest(json) == DatabaseCore.columnText(statement: row, index: 7) else { throw LingroveNotebookSyncStoreError.corruptState }
            let document = try JSONDecoder().decode(VocabularyDocument.self, from: Data(json.utf8))
            try VocabularyDocumentValidation.validate(document)
            return .init(id: DatabaseCore.columnText(statement: row, index: 0), binding: binding,
                original: .init(workspaceId: binding.scope.workspaceID.uuidString.lowercased(), notebookId: book,
                    revision: UInt64(DatabaseCore.columnInt64(statement: row, index: 5)), document: document, generation: binding.generation),
                remoteEntryCount: Int(DatabaseCore.columnInt64(statement: row, index: 8)), completed: DatabaseCore.columnInt64(statement: row, index: 9) == 1)
        }.first
    }

    public func resolveFirst(_ session: LingroveNotebookFirstConnection, merge: Bool) throws {
        try core.inTransaction {
            guard let current = try firstConnectionInTransaction(binding: session.binding), current.id == session.id, !current.completed,
                  try LingroveNotebookStore(core: core).readSnapshot(workspaceId: current.original.workspaceId).revision == current.original.revision else {
                throw VocabularyError.editConflict
            }
            try core.execute(sql: "UPDATE notebook_first_connections SET decision=?,authorized_generation=? WHERE workspace_id=? AND recovery_id=? AND completed=0",
                values: [.text(merge ? "merge" : "remote"), .text(session.binding.generation), .text(current.original.workspaceId), .text(session.id)])
        }
    }

    /// Byte GC calls this alongside live/frozen references. A user choosing the
    /// account copy has not authorized deleting their saved local PNG evidence.
    public func retainedImageReferences(workspaceID: String) throws -> Set<VocabularyImageReference> {
        try core.query(sql: "SELECT original_json,original_sha256 FROM notebook_first_connections WHERE workspace_id=?", values: [.text(workspaceID)]) { row in
            let json = DatabaseCore.columnText(statement: row, index: 0)
            guard digest(json) == DatabaseCore.columnText(statement: row, index: 1) else { throw LingroveNotebookSyncStoreError.corruptState }
            return Set(VocabularyDocumentValidation.imageReferences(try JSONDecoder().decode(VocabularyDocument.self, from: Data(json.utf8))))
        }.reduce(into: Set<VocabularyImageReference>()) { $0.formUnion($1) }
    }
    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Called in the existing link transaction before settings adopt the new
    /// identity. Its trusted session supplies owner, endpoint and auth kind.
    public func bindInTransaction(_ account: CloudLinkedSession) throws {
        let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
        if let old = try scope(account.workspaceId) {
            guard old.owner == nil || old.owner?.utf8.elementsEqual(account.userId.utf8) == true,
                  old.endpoint.isEmpty || old.endpoint == account.apiBaseUrl else { throw LingroveNotebookAccountError.ownerMismatch }
        }
        try core.execute(sql: """
            INSERT INTO notebook_account_scopes(workspace_id,owner_user_id,api_base_url,installation_id,scope_kind)
            VALUES(?,?,?,?,?) ON CONFLICT(workspace_id) DO UPDATE SET owner_user_id=excluded.owner_user_id,
              api_base_url=excluded.api_base_url,scope_kind=excluded.scope_kind
            """, values: [.text(account.workspaceId), .text(account.userId), .text(account.apiBaseUrl), .text(settings.installationId),
                .text(account.authorization.isGuest ? "guest" : "linked")])
        if let installation = try scope(account.workspaceId)?.installation, installation != settings.installationId {
            try core.execute(sql: "UPDATE app_local_settings SET installation_id=? WHERE settings_id=1", values: [.text(installation)])
        }
        try core.execute(sql: "INSERT INTO notebook_active_endpoint(settings_id,api_base_url) VALUES(1,?) ON CONFLICT(settings_id) DO UPDATE SET api_base_url=excluded.api_base_url",
            values: [.text(account.apiBaseUrl)])
    }

    public func captureActiveScopeInTransaction(endpoint: String? = nil) throws {
        let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
        guard let active = settings.activeWorkspaceId else { return }
        try core.execute(sql: """
            INSERT OR IGNORE INTO notebook_account_scopes(workspace_id,owner_user_id,installation_id,scope_kind) VALUES(?,?,?,?)
            """, values: [.text(active), settings.linkedUserId.map(SQLiteValue.text) ?? .null, .text(settings.installationId),
                .text(settings.cloudState == .disconnected ? "local" : settings.cloudState.rawValue)])
        if let owner = settings.linkedUserId, settings.cloudState != .disconnected {
            if let old = try scope(active)?.owner, !old.utf8.elementsEqual(owner.utf8) { throw LingroveNotebookAccountError.ownerMismatch }
            try core.execute(sql: "UPDATE notebook_account_scopes SET owner_user_id=?,scope_kind=? WHERE workspace_id=? AND owner_user_id IS NULL",
                values: [.text(owner), .text(settings.cloudState.rawValue), .text(active)])
        }
        if let endpoint, settings.linkedUserId != nil {
            try core.execute(sql: "UPDATE notebook_account_scopes SET api_base_url=? WHERE workspace_id=? AND api_base_url='' AND owner_user_id=? COLLATE BINARY",
                values: [.text(endpoint), .text(active), .text(settings.linkedUserId ?? "")])
        }
    }

    public func installation(for account: CloudLinkedSession) throws -> UUID {
        try core.inTransaction {
            let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
            guard settings.activeWorkspaceId == account.workspaceId,
                  settings.linkedUserId?.utf8.elementsEqual(account.userId.utf8) == true else {
                throw LingroveNotebookAccountError.ownerMismatch
            }
            try bindInTransaction(account)
            guard let value = try scope(account.workspaceId), let id = UUID(uuidString: value.installation) else {
                throw LingroveNotebookAccountError.ownerMismatch
            }
            return id
        }
    }

    public func proposeInTransaction(source: String, account: CloudLinkedSession, guestCardsAlreadyMerged: Bool = false) throws {
        guard source != account.workspaceId else { return }
        let sourceKind = try scope(source)?.kind ?? "local"
        guard sourceKind != "linked",
              try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_state WHERE workspace_id=? AND revision>0", values: [.text(source)]) > 0 else { return }
        try core.execute(sql: """
            INSERT INTO notebook_ownership_proposals(proposal_id,source_workspace_id,target_workspace_id,owner_user_id,guest_cards_merged)
            VALUES(?,?,?,?,?) ON CONFLICT(target_workspace_id,owner_user_id,source_workspace_id) DO NOTHING
            """, values: [.text(UUID().uuidString.lowercased()), .text(source), .text(account.workspaceId), .text(account.userId), .integer(guestCardsAlreadyMerged ? 1 : 0)])
    }

    public func proposal(workspaceID: String, proposalID: String? = nil) throws -> LingroveNotebookOwnershipProposal? {
        try core.inTransaction {
            let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
            guard settings.activeWorkspaceId == workspaceID, let owner = settings.linkedUserId else { return nil }
            let ids = try core.query(sql: """
                SELECT proposal_id,source_workspace_id,status,guest_cards_merged FROM notebook_ownership_proposals
                WHERE target_workspace_id=? AND owner_user_id=? AND (? IS NULL OR proposal_id=?)
                ORDER BY CASE status WHEN 'pending' THEN 0 WHEN 'separate' THEN 1 ELSE 2 END,rowid DESC LIMIT 1
                """, values: [.text(workspaceID), .text(owner), proposalID.map(SQLiteValue.text) ?? .null, proposalID.map(SQLiteValue.text) ?? .null]) {
                    (DatabaseCore.columnText(statement: $0, index: 0), DatabaseCore.columnText(statement: $0, index: 1), DatabaseCore.columnText(statement: $0, index: 2), DatabaseCore.columnInt64(statement: $0, index: 3) == 1)
                }
            guard let pair = ids.first else { return nil }
            let store = LingroveNotebookStore(core: core)
            // The linked shell can be reached before either the browser or
            // network runner has created its revision-zero notebook header.
            try ensureNotebookInTransaction(workspaceID)
            let source = try store.readSnapshot(workspaceId: pair.1), target = try store.readSnapshot(workspaceId: workspaceID)
            let candidates: [VocabularyWireConflictSelection]
            let canCombine: Bool
            do { _ = try mergedDocument(source: source.document, target: target.document, notebookID: target.notebookId); candidates = []; canCombine = true }
            catch let VocabularyWireRebaseError.conflicts(conflicts) {
                let left = try VocabularyWireProjectionCodec.project(source.document, notebookID: target.notebookId).entities
                let right = try VocabularyWireProjectionCodec.project(target.document, notebookID: target.notebookId).entities
                candidates = conflicts.map { item in .init(conflict: item,
                    local: left.first { $0.entityType == item.entityType && $0.entityID == item.entityID },
                    remote: right.first { $0.entityType == item.entityType && $0.entityID == item.entityID }, remoteVersion: nil, choice: .remote) }
                canCombine = !candidates.isEmpty
            } catch { candidates = []; canCombine = false }
            return .init(id: pair.0, sourceWorkspaceID: pair.1, targetWorkspaceID: workspaceID, ownerUserID: owner,
                generation: try LingroveNotebookLocalScopeStore(core: core).generationInTransaction(),
                source: source, target: target, status: pair.2, conflicts: candidates, guestCardsAlreadyMerged: pair.3, canCombine: canCombine)
        }
    }

    public func sourceOptions(workspaceID: String) throws -> [LingroveNotebookOwnershipSourceOption] {
        let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
        guard settings.activeWorkspaceId == workspaceID, let owner = settings.linkedUserId else { return [] }
        return try core.query(sql: """
            SELECT p.proposal_id,w.name,n.updated_at,(SELECT count(*) FROM notebook_entries e WHERE e.workspace_id=p.source_workspace_id)
            FROM notebook_ownership_proposals p JOIN workspaces w ON w.workspace_id=p.source_workspace_id
            JOIN notebook_state n ON n.workspace_id=p.source_workspace_id WHERE p.target_workspace_id=? AND p.owner_user_id=?
            ORDER BY p.rowid DESC
            """, values: [.text(workspaceID), .text(owner)]) {
                .init(id: DatabaseCore.columnText(statement: $0, index: 0), name: DatabaseCore.columnText(statement: $0, index: 1),
                    entryCount: Int(DatabaseCore.columnInt64(statement: $0, index: 3)), updatedAt: DatabaseCore.columnText(statement: $0, index: 2))
            }
    }

    /// Choice + copied public/private content + media registration + journal
    /// commit together through the normal notebook save path. Source requests,
    /// review enrollments and append-only history remain in the source scope.
    public func resolve(_ proposal: LingroveNotebookOwnershipProposal, merge: Bool,
                 choices: [Int: VocabularyWireConflictSelection.Choice] = [:]) throws -> LingroveNotebookSnapshot {
        // Validate only source-owned bytes before the writer transaction. A
        // shared digest cannot grant the target access by itself.
        let images: [String: Data]
        if merge {
            images = try core.inReadTransaction {
                try validate(proposal)
                let media = LingroveNotebookMediaStore(core: core)
                return try Dictionary(uniqueKeysWithValues: Set(VocabularyDocumentValidation.imageReferences(proposal.source.document)).map {
                    ($0.filename, try media.imageInTransaction($0, scope: proposal.source))
                })
            }
        } else { images = [:] }
        let media = LingroveNotebookMediaStore(core: core)
        let selections: [VocabularyWireConflictSelection] = try (merge ? proposal.conflicts : []).enumerated().map { index, candidate in
            guard let choice = choices[index] else { throw VocabularyWireRebaseError.staleResolution }
            return VocabularyWireConflictSelection(conflict: candidate.conflict, local: candidate.local, remote: candidate.remote,
                remoteVersion: nil, choice: choice)
        }
        let materialization = try merge ? mergedDocument(source: proposal.source.document, target: proposal.target.document,
            notebookID: proposal.target.notebookId, resolving: selections) : nil
        let document = materialization?.document ?? proposal.target.document
        let staged = try media.stageSuppliedImages(document: document, supplied: images)
        return try core.inTransaction {
            try validate(proposal)
            let store = LingroveNotebookStore(core: core)
            let target = try store.readSnapshot(workspaceId: proposal.targetWorkspaceID)
            guard target.revision == proposal.target.revision,
                  try store.readSnapshot(workspaceId: proposal.sourceWorkspaceID).revision == proposal.source.revision else { throw VocabularyError.editConflict }
            let result: LingroveNotebookSnapshot
            if merge {
                result = try store.saveInAccountTransaction(document, basedOn: target, staged: staged, operationID: "ownership-" + proposal.id)
                if let materialization {
                    let old = try privateRemainderInTransaction(workspaceID: target.workspaceId, localNotebookID: target.notebookId, remoteNotebookID: target.notebookId)
                    let state = Self.combinePrivate(old, materialization.unattachedPrivateState, notebookID: target.notebookId)
                    let json = try LingroveNotebookPrivateStateCodec.encode(state)
                    try core.execute(sql: """
                        INSERT INTO notebook_account_private_remainders(workspace_id,local_notebook_id,private_json,private_sha256) VALUES(?,?,?,?)
                        ON CONFLICT(workspace_id) DO UPDATE SET private_json=excluded.private_json,private_sha256=excluded.private_sha256
                        """, values: [.text(target.workspaceId), .text(target.notebookId.uuidString), .text(json), .text(digest(json))])
                }
                let settings = WorkspaceSettingsStore(core: core)
                let shell = WorkspaceShellStore(core: core, workspaceSettingsStore: settings)
                try WorkspaceForker(core: core, workspaceSettingsStore: settings, shellStore: shell,
                    mediaTransferStore: MediaTransferStore(core: core), outboxRewriter: WorkspaceOutboxRewriter(core: core))
                    .copyForNotebookOwnership(sourceWorkspaceID: proposal.sourceWorkspaceID, targetWorkspaceID: target.workspaceId,
                        notebookID: target.notebookId, managedOnly: proposal.guestCardsAlreadyMerged)
                // The fork has now journaled the initial held Cards. Refresh
                // their new target provenance only afterwards, so any generated
                // face update follows creation and admission is never guessed.
                try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(
                    store.readSnapshot(workspaceId: target.workspaceId))
            } else { result = target }
            try core.execute(sql: "UPDATE notebook_ownership_proposals SET status=? WHERE proposal_id=?",
                values: [.text(merge ? "merged" : "separate"), .text(proposal.id)])
            return result
        }
    }

    public func hasPendingProposal(workspaceID: String) throws -> Bool {
        try core.scalarInt(sql: "SELECT EXISTS(SELECT 1 FROM notebook_ownership_proposals WHERE target_workspace_id=? AND status='pending')",
            values: [.text(workspaceID)]) != 0
    }

    /// Sign-out changes the active identity without deleting account data.
    /// The retained installation IDs allow exact frozen replica recovery later.
    public func isolateForSignOut() throws {
        try core.inTransaction { try isolateInTransaction() }
    }

    /// Confirmed deletion is scoped to this authenticated owner and endpoint.
    /// Explicit device-wide erase continues using the separate schema reset.
    public func eraseCurrentAccountAndIsolate(endpoint: String) throws {
        try core.inTransaction {
            let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
            guard let owner = settings.linkedUserId else { throw LingroveNotebookAccountError.ownerMismatch }
            try captureActiveScopeInTransaction(endpoint: endpoint)
            let workspaces = try core.query(sql: "SELECT workspace_id FROM notebook_account_scopes WHERE owner_user_id=? COLLATE BINARY AND (api_base_url=? OR api_base_url='')",
                values: [.text(owner), .text(endpoint)]) { DatabaseCore.columnText(statement: $0, index: 0) }
            for workspace in workspaces {
                try core.execute(sql: "DELETE FROM notebook_ownership_proposals WHERE target_workspace_id=?", values: [.text(workspace)])
            }
            try isolateInTransaction()
            for workspace in workspaces {
                try core.execute(sql: "DELETE FROM workspaces WHERE workspace_id=?", values: [.text(workspace)])
            }
        }
    }

    private func isolateInTransaction() throws {
            let settings = WorkspaceSettingsStore(core: core)
            let source = try settings.loadWorkspace()
            let config = try settings.loadCloudSettings()
            try captureActiveScopeInTransaction()
            try core.execute(sql: """
                INSERT OR IGNORE INTO notebook_account_scopes(workspace_id,owner_user_id,installation_id,scope_kind)
                VALUES(?,?,?,?)
                """, values: [.text(source.workspaceId), config.linkedUserId.map(SQLiteValue.text) ?? .null,
                    .text(config.installationId), .text(config.cloudState == .disconnected ? "local" : config.cloudState.rawValue)])
            let fresh = UUID().uuidString.lowercased()
            let shell = WorkspaceShellStore(core: core, workspaceSettingsStore: settings)
            try shell.insertWorkspaceShell(workspace: .init(workspaceId: fresh, name: "Personal", createdAt: nowIsoTimestamp(), isSelected: true))
            try shell.ensureSyncStateExists(workspaceId: fresh)
            try core.execute(sql: "DELETE FROM user_settings", values: [])
            try core.execute(sql: "INSERT INTO user_settings(user_id,workspace_id,email,locale,created_at) VALUES('local-user',?,NULL,?,?)",
                values: [.text(fresh), .text(Locale.current.language.languageCode?.identifier ?? "en"), .text(nowIsoTimestamp())])
            try core.execute(sql: "UPDATE app_local_settings SET installation_id=? WHERE settings_id=1", values: [.text(UUID().uuidString.lowercased())])
            try settings.updateCloudSettings(cloudState: .disconnected, linkedUserId: nil, linkedWorkspaceId: nil, activeWorkspaceId: fresh, linkedEmail: nil)
    }

    private func validate(_ proposal: LingroveNotebookOwnershipProposal) throws {
        let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
        guard settings.activeWorkspaceId == proposal.targetWorkspaceID,
              settings.linkedUserId?.utf8.elementsEqual(proposal.ownerUserID.utf8) == true,
              try LingroveNotebookLocalScopeStore(core: core).generationInTransaction() == proposal.generation,
              try core.query(sql: "SELECT status FROM notebook_ownership_proposals WHERE proposal_id=? AND source_workspace_id=? AND target_workspace_id=? AND owner_user_id=?",
                values: [.text(proposal.id), .text(proposal.sourceWorkspaceID), .text(proposal.targetWorkspaceID), .text(proposal.ownerUserID)],
                map: { DatabaseCore.columnText(statement: $0, index: 0) }).first == proposal.status,
              proposal.status != "merged" else {
            throw LingroveNotebookAccountError.ownerMismatch
        }
    }
    private func scope(_ workspace: String) throws -> (owner: String?, endpoint: String, installation: String, kind: String)? {
        try core.query(sql: "SELECT owner_user_id,api_base_url,installation_id,scope_kind FROM notebook_account_scopes WHERE workspace_id=?",
            values: [.text(workspace)]) { (DatabaseCore.columnOptionalText(statement: $0, index: 0), DatabaseCore.columnText(statement: $0, index: 1),
                DatabaseCore.columnText(statement: $0, index: 2), DatabaseCore.columnText(statement: $0, index: 3)) }.first
    }
    private func ensureNotebookInTransaction(_ workspace: String) throws {
        try core.execute(sql: "INSERT OR IGNORE INTO notebook_state(workspace_id,notebook_id,revision,has_templates,updated_at) VALUES(?,?,0,0,?)",
            values: [.text(workspace), .text(UUID().uuidString), .text(nowIsoTimestamp())])
    }
    private func mergedDocument(source: VocabularyDocument, target: VocabularyDocument, notebookID: UUID,
                                resolving selections: [VocabularyWireConflictSelection] = []) throws -> VocabularyWireMaterialization {
        // This is first ownership reconciliation, not conflict resolution.
        // Stable identities and literal fields must agree before union; no
        // same-ID value or duplicate expression is silently overwritten.
        let right = try VocabularyWireProjectionCodec.project(target, notebookID: notebookID)
        let left = try VocabularyWireProjectionCodec.project(source, notebookID: notebookID, retaining: right.privateState)
        var values = Dictionary(uniqueKeysWithValues: right.entities.map { ($0.entityType.rawValue + ":" + $0.entityID, $0) })
        var conflicts: [VocabularyWireConflict] = []
        let all = Dictionary(uniqueKeysWithValues: left.entities.map { ($0.entityType.rawValue + ":" + $0.entityID, $0) })
        let keys = Set(all.keys).union(values.keys)
        for key in keys.sorted() {
            let local = all[key], remote = values[key]
            if let selected = selections.first(where: { $0.conflict.entityType == (local ?? remote)?.entityType && $0.conflict.entityID == (local ?? remote)?.entityID && $0.conflict.reason == .relationshipChanged }) {
                guard selected.local == local, selected.remote == remote else { throw VocabularyWireRebaseError.staleResolution }
                values[key] = selected.choice == .local ? local : remote
                continue
            }
            guard let entity = local else { continue }
            if let old = values[key], !VocabularyWireJSON.object(old.fields).hasSameWireValue(as: .object(entity.fields)) {
                // Root presence flags describe the target collection shape;
                // source templates are materialized below only if compatible.
                if entity.entityType == .notebookSettings {
                    var fields = old.fields
                    fields["reviewTemplatesPresent"] = .bool(source.reviewTemplates != nil || target.reviewTemplates != nil)
                    values[key] = .init(entityType: .notebookSettings, entityID: entity.entityID, fields: fields)
                    continue
                }
                var fields = old.fields
                for field in Set(entity.fields.keys).union(old.fields.keys).sorted() {
                    if sameWireValue(entity.fields[field], old.fields[field]) { continue }
                    if field == "updatedAt", case let .number(a)? = entity.fields[field], case let .number(b)? = old.fields[field] {
                        fields[field] = .number(max(a,b)); continue
                    }
                    // Official directory identity/rank is not personal intent.
                    if field == "rank", [.classificationFramework,.category,.categoryParent].contains(entity.entityType) { continue }
                    let item = VocabularyWireConflict(entityType: entity.entityType, entityID: entity.entityID, field: field, reason: .fieldChanged)
                    if let selection = selections.first(where: { $0.conflict == item }), selection.local == entity, selection.remote == old {
                        fields[field] = selection.choice == .local ? entity.fields[field] : old.fields[field]
                    } else { conflicts.append(item) }
                }
                values[key] = .init(entityType: entity.entityType, entityID: entity.entityID, fields: fields)
                continue
            }
            values[key] = entity
        }
        guard conflicts.isEmpty else { throw VocabularyWireRebaseError.conflicts(conflicts) }
        do {
            return try VocabularyWireProjectionCodec.materializeComplete(Array(values.values), notebookID: notebookID,
                preserving: left.privateState)
        } catch {
            throw VocabularyWireRebaseError.conflicts(keys.sorted().compactMap { key in
                guard all[key] != right.entities.first(where: { $0.entityType.rawValue + ":" + $0.entityID == key }),
                      let entity = all[key] ?? values[key] else { return nil }
                return .init(entityType: entity.entityType, entityID: entity.entityID, field: nil, reason: .relationshipChanged)
            })
        }
    }
    private func sameWireValue(_ left: VocabularyWireJSON?, _ right: VocabularyWireJSON?) -> Bool {
        switch (left, right) {
        case (nil, nil): true
        case let (a?, b?): a.hasSameWireValue(as: b)
        default: false
        }
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
