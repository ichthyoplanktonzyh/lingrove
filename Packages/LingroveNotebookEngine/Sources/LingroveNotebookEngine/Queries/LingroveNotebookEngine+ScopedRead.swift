import Foundation
import LingroveNotebook

extension LingroveNotebookEngine {
    /// Synchronous readers compose their SQL under one account/revision fence. The closure
    /// cannot suspend, so media metadata and bytes belong to the same SQLite read snapshot.
    public func withNotebookRead<T>(version: LingroveNotebookVersion, _ read: () throws -> T) throws -> T {
        try core.inReadTransaction {
            try Task.checkCancellation()
            guard try currentNotebookVersionInTransaction() == version else { throw VocabularyError.editConflict }
            return try read()
        }
    }

    /// Rendering needs the exact saved card and link, including same-revision review edits.
    /// Loading the complete corpus would add no protection to these identity checks.
    public func withBuiltInReviewCardRead<T>(version: LingroveNotebookVersion, card: Card,
                                            link: LingroveNotebookCardLink, _ read: () throws -> T) throws -> T {
        try withNotebookRead(version: version) {
            guard card.workspaceId == version.workspaceId, link.cardId == card.cardId,
                  link.source.workspaceId == version.workspaceId, link.source.notebookId == version.notebookId,
                  try cardStore.loadOptionalCardIncludingDeleted(workspaceId: version.workspaceId, cardId: card.cardId) == card,
                  try lingroveNotebookCardLinkStore.find(workspaceId: version.workspaceId, id: link.id) == link,
                  link.deletedAt == nil else { throw VocabularyError.editConflict }
            _ = try requireValidBuiltInReviewCard(card)
            return try read()
        }
    }
}
