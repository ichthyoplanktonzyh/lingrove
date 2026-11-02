import Foundation
import LingroveNotebook

/// Native hosts keep the saved snapshot alongside a screen's draft. These commands validate
/// its durable generation while holding the same writer transaction as the resulting operation;
/// a switch away and back cannot grant an old task a new account lifetime.
extension LingroveNotebookEngine {
    public func enrollNotebookSenses(_ drafts: [LingroveNotebookCardDraft], basedOn scope: LingroveNotebookSnapshot) throws -> [LingroveNotebookReviewEnrollment] {
        guard drafts.allSatisfy({ $0.source.workspaceId == scope.workspaceId && $0.source.notebookId == scope.notebookId && $0.sourceRevision == scope.revision }) else { throw VocabularyError.editConflict }
        return try enrollLingroveNotebookSenses(drafts, scope: scope)
    }

    public func setNotebookReviewStatus(_ status: LingroveNotebookReviewStatus,
        enrollments: [LingroveNotebookReviewEnrollment], basedOn scope: LingroveNotebookSnapshot,
        requestID: UUID = UUID()) throws -> [LingroveNotebookReviewEnrollment] {
        guard enrollments.allSatisfy({ $0.workspaceId == scope.workspaceId && $0.notebookId == scope.notebookId }) else { throw VocabularyError.editConflict }
        return try setLingroveNotebookReviewStatus(status, enrollments: enrollments, requestId: requestID, scope: scope)
    }

    public func submitNotebookRating(_ submission: ReviewSubmission, basedOn scope: LingroveNotebookSnapshot,
        expectedCardOperationID: String? = nil) throws -> Card {
        try submitReview(workspaceId: scope.workspaceId, reviewSubmission: submission, scope: scope,
            expectedCardOperationID: expectedCardOperationID)
    }

    func requireCurrentScopeInTransaction(_ scope: LingroveNotebookSnapshot, requireRevision: Bool) throws {
        try lingroveNotebookCardLinkStore.requireActiveScope(workspaceId: scope.workspaceId, notebookId: scope.notebookId)
        let current = try lingroveNotebookStore.readSnapshot(workspaceId: scope.workspaceId)
        guard current.generation == scope.generation, current.notebookId == scope.notebookId,
              !requireRevision || current.revision == scope.revision else { throw VocabularyError.editConflict }
    }
}
