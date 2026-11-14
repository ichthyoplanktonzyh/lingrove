import Foundation
import LingroveNotebook
import LingroveNotebookSync

extension LingroveNotebookEngine {
    /// Mac capture/editor saves name one saved entry and its examples. The
    /// supplied baseline authorizes only its workspace/book/revision/generation; the writer loads
    /// or reuses its own SQL-verified state before preparing this bounded change. Other callers
    /// retain the full save/import API, so arbitrary replacement documents get full validation.
    public func saveNotebookEntry(_ entry: VocabularyEntry,
        basedOn baseline: LingroveNotebookSnapshot, images: [String: Data] = [:],
        operationId: String = UUID().uuidString.lowercased(), expectedCorpus: NotebookChangeToken? = nil) throws -> LingroveNotebookSnapshot {
        try Task.checkCancellation()
        let mediaDocument = VocabularyDocument(entries: [entry])
        let media = LingroveNotebookMediaStore(core: core)
        let staged: Set<VocabularyImageReference> = try images.isEmpty ? [] : media.stageSuppliedImages(document: mediaDocument, supplied: images)
        return try saveEntryChange(basedOn: baseline, staged: staged, operationId: operationId, expectedCorpus: expectedCorpus) {
            try $0.replacing(entry)
        }
    }

    /// A removal uses the same checked state and transaction as an entry edit. Its baseline
    /// fences the workspace, while SQL supplies the document and owns the resulting revision.
    public func removeNotebookSense(_ senseID: UUID, from entryID: UUID, basedOn baseline: LingroveNotebookSnapshot,
        operationId: String = UUID().uuidString.lowercased()) throws -> LingroveNotebookSnapshot {
        try saveEntryChange(basedOn: baseline, staged: [], operationId: operationId) {
            try $0.removingSense(senseID, from: entryID)
        }
    }

    public func removeNotebookEntry(_ entryID: UUID, basedOn baseline: LingroveNotebookSnapshot,
                                    operationId: String = UUID().uuidString.lowercased()) throws -> LingroveNotebookSnapshot {
        try saveEntryChange(basedOn: baseline, staged: [], operationId: operationId) { try $0.removingEntry(entryID) }
    }

    public func removeNotebookTag(_ tag: String, basedOn baseline: LingroveNotebookSnapshot,
                                  operationId: String = UUID().uuidString.lowercased()) throws -> LingroveNotebookSnapshot {
        try Task.checkCancellation()
        return try core.inTransaction {
            let store = lingroveNotebookStore
            try store.checkActiveWorkspace(baseline.workspaceId, required: true)
            let current = try store.readSnapshot(workspaceId: baseline.workspaceId)
            guard LingroveNotebookVersion(current) == LingroveNotebookVersion(baseline),
                  current.revision < UInt64(Int64.max), let cached = core.notebookSaveCache else { throw VocabularyError.editConflict }
            let change = try cached.state.removingTag(tag)
            guard !change.entryIDs.isEmpty else { return current }
            let rows = try cached.projection.applying(change)
            let plan = try LingroveNotebookSavePlan(previous: cached, state: change.state, rows: rows, knownEntryIDs: change.entryIDs)
            let publicChange = try plan.hasPublicChanges(previous: cached)
            try Task.checkCancellation()
            return try store.commit(plan, current: current, publicChange: publicChange,
                operationId: operationId, lineage: cached.lineage)
        }
    }

    private func saveEntryChange(basedOn baseline: LingroveNotebookSnapshot, staged: Set<VocabularyImageReference>,
                                 operationId: String, expectedCorpus: NotebookChangeToken? = nil, prepare: (VocabularyEntrySaveState) throws -> VocabularyEntrySaveChange)
        throws -> LingroveNotebookSnapshot {
        try Task.checkCancellation()
        return try core.inTransaction {
            if let expectedCorpus, try core.notebookChangeStamp().corpus != expectedCorpus { throw VocabularyError.editConflict }
            let store = lingroveNotebookStore
            try store.checkActiveWorkspace(baseline.workspaceId, required: true)
            let current = try store.readSnapshot(workspaceId: baseline.workspaceId)
            guard current.notebookId == baseline.notebookId, current.revision == baseline.revision,
                  current.generation == baseline.generation, current.revision < UInt64(Int64.max),
                  let cached = core.notebookSaveCache else { throw VocabularyError.editConflict }
            let change = try prepare(cached.state)
            let rows = try cached.projection.applying(change)
            let publicChange = try VocabularyWirePublicIntent.hasChanges(change, notebookID: current.notebookId)
            try LingroveNotebookMediaStore(core: core).registerImages(references: change.state.mediaReferences,
                existing: cached.state.mediaReferences, staged: staged, workspaceId: current.workspaceId)
            try Task.checkCancellation()
            let plan = try LingroveNotebookSavePlan(previous: cached, state: change.state, rows: rows, knownEntryIDs: [change.entryID])
            return try store.commit(plan, current: current, publicChange: publicChange,
                operationId: operationId, lineage: cached.lineage)
        }
    }
}
