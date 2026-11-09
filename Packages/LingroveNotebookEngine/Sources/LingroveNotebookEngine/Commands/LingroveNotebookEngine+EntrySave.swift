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
        operationId: String = UUID().uuidString.lowercased()) throws -> LingroveNotebookSnapshot {
        try Task.checkCancellation()
        let mediaDocument = VocabularyDocument(entries: [entry])
        let media = LingroveNotebookMediaStore(core: core)
        let staged = try media.stageSuppliedImages(document: mediaDocument, supplied: images)
        return try core.inTransaction {
            let store = lingroveNotebookStore
            try store.checkActiveWorkspace(baseline.workspaceId, required: true)
            let current = try store.readSnapshot(workspaceId: baseline.workspaceId)
            guard current.notebookId == baseline.notebookId, current.revision == baseline.revision,
                  current.generation == baseline.generation, current.revision < UInt64(Int64.max),
                  let cached = core.notebookSaveCache else { throw VocabularyError.editConflict }
            let change = try cached.state.replacing(entry)
            let rows = try cached.projection.applying(change)
            let publicChange = try VocabularyWirePublicIntent.hasChanges(change, notebookID: current.notebookId)
            try media.registerImages(document: change.document, previous: current.document, staged: staged, workspaceId: current.workspaceId)
            try Task.checkCancellation()
            try store.writeRows(changed: rows.changed, removed: rows.removed, workspaceId: current.workspaceId)
            let saved = try store.finishSave(change.document, current: current, changed: rows.changed,
                removed: rows.removed, publicChange: publicChange, operationId: operationId)
            core.notebookSaveCache = .init(snapshot: saved, state: change.state, projection: rows.projection,
                token: try core.notebookCacheToken(), lineage: cached.lineage)
            return saved
        }
    }
}
