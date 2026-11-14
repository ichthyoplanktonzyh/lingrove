import Foundation
import LingroveNotebook

extension LingroveNotebookEngine {
    /// The editor supplies one complete entry and its exact read fence. Both the certified
    /// command and full fallback compare the corpus clock inside their writer transaction.
    /// Only the engine loads the fallback baseline; the detail is never a partial document.
    public func saveNotebookEntry(_ entry: VocabularyEntry, basedOn detail: NotebookEntryDetail,
                                  images: [String: Data] = [:]) throws -> NotebookEntryDetail {
        try Task.checkCancellation()
        guard detail.entry?.id == entry.id else { throw VocabularyError.editConflict }
        if try trySaveNotebookEntry(entry, basedOn: detail.fence.version, images: images, expectedCorpus: detail.fence.corpus) == nil {
            let baseline = try loadLingroveNotebook(workspaceId: detail.fence.version.workspaceId, requireActiveWorkspace: true)
            guard LingroveNotebookVersion(baseline) == detail.fence.version else { throw VocabularyError.editConflict }
            _ = try saveNotebookEntry(entry, basedOn: baseline, images: images, expectedCorpus: detail.fence.corpus)
        }
        return try notebookEntryDetail(entryID: entry.id)
    }
}
