import Foundation
import LingroveNotebook
import LingroveNotebookSync

extension LingroveNotebookEngine {
    /// A local organization command borrows the connection's checked lexical state. The
    /// supplied snapshot fences the account/revision, while the edit carries only changed
    /// records and their expected values. Graph validation, row deltas and journal commit
    /// all share this transaction, so an invalid relation cannot leave a partial save.
    public func saveNotebookOrganization(_ edit: VocabularyOrganizationEdit, basedOn baseline: LingroveNotebookSnapshot,
                                         operationId: String = UUID().uuidString.lowercased()) throws -> LingroveNotebookSnapshot {
        try Task.checkCancellation()
        return try core.inTransaction {
            let store = lingroveNotebookStore
            try store.checkActiveWorkspace(baseline.workspaceId, required: true)
            let current = try store.readSnapshot(workspaceId: baseline.workspaceId)
            guard LingroveNotebookVersion(current) == LingroveNotebookVersion(baseline),
                  current.revision < UInt64(Int64.max), let cached = core.notebookSaveCache else {
                throw VocabularyError.editConflict
            }
            let state = try cached.state.editingOrganization(edit)
            let next = state.document
            guard next.semantics != current.document.semantics || next.classification != current.document.classification else {
                return current
            }
            let rows = try cached.projection.applyingOrganization(
                semantics: next.semantics == current.document.semantics ? nil : next.semantics,
                classification: next.classification == current.document.classification ? nil : next.classification)
            let publicChange = try VocabularyWirePublicIntent.hasOrganizationChanges(from: current.document,
                to: next, notebookID: current.notebookId)
            try Task.checkCancellation()
            // Organization never changes the lexical material a saved card renders.
            let plan = try LingroveNotebookSavePlan(previous: cached, state: state, rows: rows, knownEntryIDs: [])
            return try store.commit(plan, current: current, publicChange: publicChange,
                operationId: operationId, lineage: cached.lineage)
        }
    }
}
