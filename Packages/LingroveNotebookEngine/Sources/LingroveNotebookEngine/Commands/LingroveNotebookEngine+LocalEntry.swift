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
    let retiredSenseIDs: Set<UUID>
    let refreshSenseIDs: Set<UUID>
    let media: Set<VocabularyImageReference>
    let staged: Set<VocabularyImageReference>
}

extension LingroveNotebookEngine {
    /// nil requests ordinary full preparation. A cold, certified corpus can validate this
    /// closed entry fragment plus indexed global constraints without rebuilding the full snapshot.
    /// Existing warm caches keep their established incremental path and complete receipts.
    public func trySaveNotebookEntry(
        _ entry: VocabularyEntry, basedOn version: LingroveNotebookVersion, images: [String: Data] = [:],
        operationId: String = UUID().uuidString.lowercased()
    ) throws -> LingroveNotebookEntryCommit? {
        try Task.checkCancellation()
        let staged = try LingroveNotebookMediaStore(core: core).stageSuppliedImages(document: .init(entries: [entry]), supplied: images)
        return try core.inTransaction {
            guard let checkpoint = try entryCheckpoint(version) else { return nil }
            let admission = NotebookEntryAdmission(engine: self, version: version)
            guard let rows = try admission.localRows(entryID: entry.id, incoming: entry) else { return nil }
            let local = try VocabularyEntrySaveState(validating: VocabularyPersistenceCodec.decode(
                .init(rows: rows)))
            let old = local.entries.first
            let change = try local.replacing(entry)
            let projection = try VocabularyEntryRowProjection(.init(rows: rows))
            let delta = try projection.applying(change)
            guard let next = change.state.entries.first else { throw VocabularyError.invalidArchive }
            if try admission.hasExternalEvidence(next, rows: rows) { return nil }
            try admission.checkIdentities(next, previous: old)
            try admission.checkOccurrenceOwners(next)
            let media = try admission.media(after: change.state.mediaReferences, before: local.mediaReferences,
                rows: rows, checkpoint: checkpoint)
            let retired = Set(old?.senses.flatMap { [$0.id] + $0.mergedFrom } ?? [])
                .subtracting(next.senses.flatMap { [$0.id] + $0.mergedFrom })
            let isPublic = try VocabularyWirePublicIntent.hasChanges(change, notebookID: version.notebookId)
            return try commitLocalEntry(.init(checkpoint: checkpoint, entryID: entry.id, previous: old, entry: next,
                changed: delta.changed + delta.repositioned, removed: delta.removed, changesSemantics: !change.semanticChange.isEmpty,
                publicChange: isPublic, retiredSenseIDs: retired, refreshSenseIDs: try changedReviewIDs(previous: old, next: next),
                media: media, staged: staged), operationId: operationId)
        }
    }

    /// A pure retirement introduces no identities. Its canonical/historical source IDs can
    /// become unavailable without rendering another entry or changing Card memory/history.
    /// The same closed graph/media dependencies apply; unchanged live siblings need no render.
    public func tryRemoveNotebookSense(
        _ senseID: UUID, from entryID: UUID, basedOn version: LingroveNotebookVersion,
        operationId: String = UUID().uuidString.lowercased()
    ) throws -> LingroveNotebookEntryCommit? {
        try Task.checkCancellation()
        return try core.inTransaction {
            guard let checkpoint = try entryCheckpoint(version) else { return nil }
            let admission = NotebookEntryAdmission(engine: self, version: version)
            guard let rows = try admission.localRows(entryID: entryID) else { return nil }
            let local = try VocabularyEntrySaveState(validating: VocabularyPersistenceCodec.decode(
                .init(rows: rows)))
            guard let old = local.entries.first else { throw VocabularyError.invalidContent }
            let change = try local.removingSense(senseID, from: entryID)
            let projection = try VocabularyEntryRowProjection(.init(rows: rows))
            let delta = try projection.applying(change)
            let media = try admission.media(after: change.state.mediaReferences, before: local.mediaReferences,
                rows: rows, checkpoint: checkpoint)
            let retired = Set(old.senses.filter { $0.id == senseID }.flatMap { [$0.id] + $0.mergedFrom })
            return try commitLocalEntry(.init(checkpoint: checkpoint, entryID: entryID, previous: old,
                entry: change.state.entries.first, changed: delta.changed + delta.repositioned, removed: delta.removed,
                changesSemantics: !change.semanticChange.isEmpty, publicChange: true, retiredSenseIDs: retired, refreshSenseIDs: [],
                media: media, staged: []), operationId: operationId)
        }
    }

    private func entryCheckpoint(_ expected: LingroveNotebookVersion) throws -> NotebookEntryCheckpoint? {
        guard try currentNotebookVersionInTransaction() == expected, expected.revision < UInt64(Int64.max) else {
            throw VocabularyError.editConflict
        }
        guard core.notebookSaveCache == nil else { return nil }
        return try NotebookEntryCheckpoint.load(in: core, version: expected)
    }

    /// Source retirement leaves siblings unchanged. Source edits render only changed live
    /// senses, unless the shared expression/header changed. Literal JSON preserves authored
    /// Unicode distinctions without comparing unrelated corpus or graph records.
    private func changedReviewIDs(previous: VocabularyEntry?, next: VocabularyEntry) throws -> Set<UUID> {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let headerChanged = previous.map { $0.expression.utf8.elementsEqual(next.expression.utf8) } != true ||
            previous.map { $0.dictionaryForm.utf8.elementsEqual(next.dictionaryForm.utf8) } != true ||
            previous?.language != next.language || previous?.kind != next.kind
        var result = Set<UUID>()
        for sense in next.senses {
            let old = previous?.senses.first { $0.id == sense.id }
            let changed = try encoder.encode(old) != encoder.encode(sense)
            if headerChanged || changed {
                result.formUnion([sense.id] + sense.mergedFrom + (old?.mergedFrom ?? []))
            }
        }
        return result
    }

    /// The local and complete paths share row writer, revision CAS and pending journal. This
    /// path deliberately has no complete-snapshot return or full-cache installation. Every
    /// canonical statement and the replacement certificate roll back together on failure.
    private func commitLocalEntry(_ plan: NotebookLocalEntryPlan, operationId: String) throws -> LingroveNotebookEntryCommit {
        let before = plan.checkpoint.version
        let oldSenseIDs = Set(plan.previous?.senses.flatMap { [$0.id] + $0.mergedFrom } ?? [])
        guard try core.notebookCacheToken() == plan.checkpoint.token else { throw VocabularyError.editConflict }
        try LingroveNotebookMediaStore(core: core).registerImages(references: plan.media, existing: plan.checkpoint.media,
            staged: plan.staged, workspaceId: before.workspaceId)
        try Task.checkCancellation()
        if plan.changed.isEmpty && plan.removed.isEmpty {
            return .init(base: before, version: before, corpus: plan.checkpoint.token,
                entryID: plan.entryID, entry: plan.entry, previousSenseIDs: oldSenseIDs, changesSemantics: false)
        }
        let store = lingroveNotebookStore
        try store.writeRows(changed: plan.changed, removed: plan.removed, workspaceId: before.workspaceId)
        let revision = before.revision + 1, now = nowIsoTimestamp()
        let count = try core.execute(sql: """
            UPDATE notebook_state SET revision=?,updated_at=? WHERE workspace_id=? AND notebook_id=? AND revision=?
            """, values: [.integer(Int64(revision)), .text(now), .text(before.workspaceId),
                .text(before.notebookId.uuidString), .integer(Int64(before.revision))])
        guard count == 1 else { throw VocabularyError.editConflict }
        try store.recordPending(current: before, revision: revision, changed: plan.changed, removed: plan.removed,
            publicChange: plan.publicChange, operationId: operationId, now: now)
        let version = LingroveNotebookVersion(workspaceId: before.workspaceId, notebookId: before.notebookId,
            revision: revision, generation: before.generation)
        try LingroveNotebookReviewMaterialStore(core: core).retireSourcesInTransaction(version: version, senseIDs: plan.retiredSenseIDs)
        try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(version: version,
            entries: [plan.entry].compactMap { $0 }, senseIDs: plan.refreshSenseIDs.subtracting(plan.retiredSenseIDs))
        try NotebookEntryCheckpoint.record(in: core, version: version, media: plan.media)
        return try .init(base: before, version: version, corpus: core.notebookCacheToken(),
            entryID: plan.entryID, entry: plan.entry, previousSenseIDs: oldSenseIDs, changesSemantics: plan.changesSemantics)
    }
}
