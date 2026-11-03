import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec

/// Derived state owned by one DatabaseCore, accessed only under its connection lock. The token
/// includes external commits and this connection's writes (including rolled-back writes). Header
/// identity/generation is checked separately on every use. A caller's snapshot supplies only CAS;
/// it can never populate this cache or substitute its document for current durable content.
struct LingroveNotebookSaveCache {
    let snapshot: LingroveNotebookSnapshot
    let state: VocabularyEntrySaveState
    let projection: VocabularyEntryRowProjection
    let token: LingroveNotebookCacheToken
    /// A full SQL decode creates a new lineage; incremental commits retain it. Integration checks
    /// can establish reuse/invalidation without measuring latency or adding production telemetry.
    let lineage: UUID
}

struct LingroveNotebookCacheToken: Equatable {
    let externalVersion: Int
    let connectionChanges: Int64
}
