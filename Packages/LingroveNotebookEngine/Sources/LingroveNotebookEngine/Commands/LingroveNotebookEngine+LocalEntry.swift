import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec
import LingroveNotebookSync

/// A local command returns its changed owner, never a partial document pretending to be a
/// complete snapshot. The UI admits the exact corpus token before refreshing its pages.
public nonisolated struct LingroveNotebookEntryCommit: Sendable {
    public let base: LingroveNotebookVersion
    public let version: LingroveNotebookVersion
    public let corpus: NotebookChangeToken
    public let entryID: UUID
    public let entry: VocabularyEntry?
    public let previousSenseIDs: Set<UUID>
    public let changesSemantics: Bool
}

/// The synchronous writer owns this prepared bundle until COMMIT. It keeps the certificate,
/// local rows and receipt owner together; callers cannot provide unchecked changed-row lists.
private struct NotebookLocalEntryPlan {
    let checkpoint: NotebookEntryCheckpoint
    let entryID: UUID
    let previous: VocabularyEntry?
    let entry: VocabularyEntry?
    let changed: [VocabularyPersistenceRow]
    let removed: [VocabularyPersistenceRow]
    let changesSemantics: Bool
    let publicChange: Bool
}

extension LingroveNotebookEngine {
    /// nil requests ordinary full preparation. A cold, certified corpus can validate this
    /// lexical fragment plus indexed global constraints without rebuilding the full snapshot.
    /// Existing warm caches keep their established incremental path and complete receipts.
    public func trySaveNotebookEntry(
        _ entry: VocabularyEntry, basedOn version: LingroveNotebookVersion,
        operationId: String = UUID().uuidString.lowercased()
    ) throws -> LingroveNotebookEntryCommit? {
        try Task.checkCancellation()
        return try core.inTransaction {
            guard let checkpoint = try entryCheckpoint(version) else { return nil }
            let rows = try notebookEntryRowsInTransaction(entryID: entry.id.uuidString, workspace: version.workspaceId)
            let local = try VocabularyEntrySaveState(validating: VocabularyPersistenceCodec.decode(
                .init(rows: rows, reviewTemplatesPresent: false)))
            let old = local.entries.first
            let admission = NotebookEntryAdmission(engine: self, version: version)
            if try admission.hasReviewConsumers([old, entry].compactMap { $0 }) || admission.hasExternalEvidence(entry, rows: rows) {
                return nil
            }
            guard Set(old?.senses.map(\.id) ?? []).isSubset(of: Set(entry.senses.map(\.id))) else { return nil }
            let change = try local.replacing(entry)
            guard change.state.mediaReferences == local.mediaReferences else { return nil }
            let projection = try VocabularyEntryRowProjection(.init(rows: rows, reviewTemplatesPresent: false))
            let delta = try projection.applying(change)
            // Changing/removing an existing interpretation can retract citations in another
            // sense. The broader reconciling path still owns those edits in this stage.
            let oldClaims = Set(rows.filter { $0.entity == .usages }.map(\.key))
            if !(delta.changed + delta.removed).allSatisfy({ !oldClaims.contains($0.key) }) || !delta.repositioned.isEmpty {
                return nil
            }
            guard let next = change.state.entries.first else { throw VocabularyError.invalidArchive }
            if try admission.hasExternalEvidence(next, rows: rows) { return nil }
            try admission.checkIdentities(next, previous: old)
            let isPublic = try VocabularyWirePublicIntent.hasChanges(change, notebookID: version.notebookId)
            return try commitLocalEntry(.init(checkpoint: checkpoint, entryID: entry.id, previous: old, entry: next,
                changed: delta.changed, removed: delta.removed, changesSemantics: false,
                publicChange: isPublic), operationId: operationId)
        }
    }

    /// A pure retirement introduces no identities. Incoming cross-sense citations, material
    /// consumers or a changed media set require the full path, preserving their existing rules.
    public func tryRemoveNotebookSense(
        _ senseID: UUID, from entryID: UUID, basedOn version: LingroveNotebookVersion,
        operationId: String = UUID().uuidString.lowercased()
    ) throws -> LingroveNotebookEntryCommit? {
        try Task.checkCancellation()
        return try core.inTransaction {
            guard let checkpoint = try entryCheckpoint(version) else { return nil }
            let rows = try notebookEntryRowsInTransaction(entryID: entryID.uuidString, workspace: version.workspaceId)
            let local = try VocabularyEntrySaveState(validating: VocabularyPersistenceCodec.decode(
                .init(rows: rows, reviewTemplatesPresent: false)))
            guard let old = local.entries.first else { throw VocabularyError.invalidContent }
            let admission = NotebookEntryAdmission(engine: self, version: version)
            if try admission.hasReviewConsumers([old]) || admission.hasForeignCitations(senseID: senseID, entry: old) { return nil }
            let change = try local.removingSense(senseID, from: entryID)
            guard change.state.mediaReferences == local.mediaReferences else { return nil }
            let projection = try VocabularyEntryRowProjection(.init(rows: rows, reviewTemplatesPresent: false))
            let delta = try projection.applying(change)
            guard delta.repositioned.isEmpty else { return nil }
            let semantic = try admission.retiredSemanticRows(senseID: senseID)
            return try commitLocalEntry(.init(checkpoint: checkpoint, entryID: entryID, previous: old,
                entry: change.state.entries.first, changed: delta.changed, removed: delta.removed + semantic,
                changesSemantics: !semantic.isEmpty, publicChange: true), operationId: operationId)
        }
    }

    private func entryCheckpoint(_ expected: LingroveNotebookVersion) throws -> NotebookEntryCheckpoint? {
        guard try currentNotebookVersionInTransaction() == expected, expected.revision < UInt64(Int64.max) else {
            throw VocabularyError.editConflict
        }
        guard core.notebookSaveCache == nil else { return nil }
        return try NotebookEntryCheckpoint.load(in: core, version: expected)
    }

    /// The local and complete paths share row writer, revision CAS and pending journal. This
    /// path deliberately has no complete-snapshot return or full-cache installation. Every
    /// canonical statement and the replacement certificate roll back together on failure.
    private func commitLocalEntry(_ plan: NotebookLocalEntryPlan, operationId: String) throws -> LingroveNotebookEntryCommit {
        let before = plan.checkpoint.version
        let oldSenseIDs = Set(plan.previous?.senses.flatMap { [$0.id] + $0.mergedFrom } ?? [])
        guard try core.notebookCacheToken() == plan.checkpoint.token else { throw VocabularyError.editConflict }
        try LingroveNotebookMediaStore(core: core).registerImages(references: plan.checkpoint.media, existing: plan.checkpoint.media,
            staged: [], workspaceId: before.workspaceId)
        try Task.checkCancellation()
        if plan.changed.isEmpty && plan.removed.isEmpty {
            return .init(base: before, version: before, corpus: plan.checkpoint.token,
                entryID: plan.entryID, entry: plan.entry, previousSenseIDs: oldSenseIDs, changesSemantics: false)
        }
        let store = lingroveNotebookStore
        try store.writeRows(changed: plan.changed, removed: plan.removed, workspaceId: before.workspaceId)
        let revision = before.revision + 1, now = nowIsoTimestamp()
        let hasTemplates = try core.scalarInt(sql: "SELECT has_templates FROM notebook_state WHERE workspace_id=?",
            values: [.text(before.workspaceId)]) != 0
        let count = try core.execute(sql: """
            UPDATE notebook_state SET revision=?,updated_at=? WHERE workspace_id=? AND notebook_id=? AND revision=?
            """, values: [.integer(Int64(revision)), .text(now), .text(before.workspaceId),
                .text(before.notebookId.uuidString), .integer(Int64(before.revision))])
        guard count == 1 else { throw VocabularyError.editConflict }
        try store.recordPending(current: before, revision: revision, changed: plan.changed, removed: plan.removed,
            reviewTemplatesPresent: hasTemplates, publicChange: plan.publicChange, operationId: operationId, now: now)
        let version = LingroveNotebookVersion(workspaceId: before.workspaceId, notebookId: before.notebookId,
            revision: revision, generation: before.generation)
        try NotebookEntryCheckpoint.record(in: core, version: version, media: plan.checkpoint.media)
        return try .init(base: before, version: version, corpus: core.notebookCacheToken(),
            entryID: plan.entryID, entry: plan.entry, previousSenseIDs: oldSenseIDs, changesSemantics: plan.changesSemantics)
    }
}
