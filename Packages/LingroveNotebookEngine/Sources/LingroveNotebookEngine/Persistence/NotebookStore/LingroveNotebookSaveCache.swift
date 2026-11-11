import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec

/// Derived state owned by one DatabaseCore, accessed only under its connection lock. The token
/// follows corpus rows across connections; ratings and upload receipts do not evict it. Header
/// identity/generation is checked separately on every use, and rollback discards prepared state.
/// A caller's snapshot supplies only CAS;
/// it can never populate this cache or substitute its document for current durable content.
struct LingroveNotebookSaveCache {
    let snapshot: LingroveNotebookSnapshot
    let state: VocabularyEntrySaveState
    let projection: VocabularyEntryRowProjection
    let token: LingroveNotebookCacheToken
    /// A full SQL decode creates a new lineage; incremental commits retain it. Integration checks
    /// can establish reuse/invalidation without measuring latency or adding production telemetry.
    let lineage: UUID
    let committedChange: LingroveNotebookCommittedChange?

    init(snapshot: LingroveNotebookSnapshot, state: VocabularyEntrySaveState, projection: VocabularyEntryRowProjection,
         token: LingroveNotebookCacheToken, lineage: UUID, committedChange: LingroveNotebookCommittedChange? = nil) {
        self.snapshot = snapshot; self.state = state; self.projection = projection
        self.token = token; self.lineage = lineage; self.committedChange = committedChange
    }
}

typealias LingroveNotebookCacheToken = NotebookChangeToken
