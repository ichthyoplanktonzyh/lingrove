import Foundation
import LingroveNotebook

/// The database facade composes the existing Card writer with notebook provenance under one
/// writer transaction. UI and IO callers use these operations rather than coordinating two
/// saves themselves; neither Card scheduling nor the notebook document is owned by the link.
extension LingroveNotebookEngine {
    public func loadLingroveNotebookCardLinks(
        workspaceId: String, cardId: String? = nil, includingDeleted: Bool = false
    ) throws -> [LingroveNotebookCardLink] {
        try self.lingroveNotebookCardLinkStore.load(workspaceId: workspaceId, cardId: cardId, includingDeleted: includingDeleted)
    }

    public func requireCurrentNotebookCardLink(_ expected: LingroveNotebookCardLink) throws {
        try self.lingroveNotebookCardLinkStore.requireActiveScope(expected.source)
        guard try self.lingroveNotebookCardLinkStore.find(workspaceId: expected.source.workspaceId, id: expected.id) == expected,
              expected.deletedAt == nil else { throw VocabularyError.editConflict }
    }

}
