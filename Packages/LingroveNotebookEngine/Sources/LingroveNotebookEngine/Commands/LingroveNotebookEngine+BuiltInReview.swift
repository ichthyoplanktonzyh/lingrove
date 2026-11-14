import Foundation
import LingroveNotebook

/// Nonoptional saved-action entry points for the native Mac window. They compose existing
/// writers rather than nesting transactions or inventing a second rating/undo implementation.
extension LingroveNotebookEngine {
    public func setBuiltInNotebookReviewStatus(_ status: LingroveNotebookReviewStatus,
                                              action: NotebookBuiltInReviewAction, requestID: UUID) throws {
        _ = try setLingroveNotebookReviewStatus(status, enrollments: action.enrollments,
            requestId: requestID, scope: action.scope, action: action)
    }

    public func submitBuiltInNotebookRating(_ submission: ReviewSubmission, card: Card,
                                           action: NotebookBuiltInReviewAction) throws -> Card {
        guard submission.cardId == card.cardId, action.cards.contains(card) else { throw VocabularyError.editConflict }
        return try submitReview(workspaceId: action.scope.workspaceId, reviewSubmission: submission,
            scope: action.scope, expectedCardOperationID: card.lastOperationId, validateCurrentState: {
                // The generic writer supplies this precondition inside its transaction, before
                // reading or scheduling the Card. A stale or invalid row therefore cannot be
                // normalized into an apparently fresh question before the fence sees it.
                try self.requireBuiltInReviewActionInTransaction(action)
            })
    }

    public func undoBuiltInNotebookRating(_ identity: NotebookBuiltInReviewUndo,
                                         action: NotebookBuiltInReviewAction) throws {
        guard action.cards.contains(where: {
            $0.cardId == identity.cardID && $0.lastOperationId == identity.cardOperationID
        }) else { throw VocabularyError.editConflict }
        try undoLastNotebookRating(workspaceId: action.scope.workspaceId, cardId: identity.cardID,
            generation: action.scope.generation, scope: action.scope,
            expectedCardOperationID: identity.cardOperationID,
            expectedRatingOperationID: identity.ratingOperationID, action: action)
    }

    /// Call only while the existing command owns its writer transaction. This fence is not
    /// authorization by UI preflight: every compared row is read under the same SQLite lock as
    /// the resulting write, including ABA generation and same-generation review changes.
    func requireBuiltInReviewActionInTransaction(_ action: NotebookBuiltInReviewAction) throws {
        try requireCurrentScopeInTransaction(action.scope, requireRevision: true)
        let version = LingroveNotebookVersion(action.scope)
        let displayedIDs = Set(action.cards.map(\.cardId))
        let noteCards = try ReviewNoteStore(core: core).cardModels(version: version, cardIDs: displayedIDs)
        guard noteCards == action.noteCards else { throw VocabularyError.editConflict }
        let matching: [LingroveNotebookReviewEnrollment]
        if let saved = try notebookSense(id: action.selection.senseID, workspace: version.workspaceId),
           saved.selection == action.selection {
            matching = try lingroveNotebookReviewStore.load(workspaceId: version.workspaceId,
                notebookId: version.notebookId, senseIDs: Set([saved.sense.id] + saved.sense.mergedFrom))
        } else {
            // An explicitly retained question can outlive its source. Only its pinned
            // enrollments qualify, and an ID that now resolves elsewhere cannot be adopted.
            matching = try action.enrollments.compactMap { expected in
                guard let stored = try lingroveNotebookReviewStore.find(workspaceId: version.workspaceId, id: expected.id),
                      stored.notebookId == version.notebookId,
                      try resolvedNotebookSelection(senseID: stored.senseId, workspace: version.workspaceId) == nil else {
                    return nil
                }
                return stored
            }
        }
        guard Set(matching) == Set(action.enrollments),
              try workspaceSettingsStore.loadWorkspaceSchedulerSettings(workspaceId: version.workspaceId) == action.schedulerSettings
        else { throw VocabularyError.editConflict }
        for card in action.cards {
            let stored = try cardStore.loadOptionalCardIncludingDeleted(workspaceId: version.workspaceId, cardId: card.cardId)
            guard try requireValidBuiltInReviewCard(stored) == card else {
                throw VocabularyError.editConflict
            }
        }
        let cardIDs = Set(action.cards.map(\.cardId))
        let currentLinks = try cardIDs.flatMap {
            try lingroveNotebookCardLinkStore.load(workspaceId: version.workspaceId, cardId: $0)
        }
        guard Set(currentLinks) == Set(action.links) else { throw VocabularyError.editConflict }
        for link in action.links { try requireCurrentNotebookCardLink(link) }
    }

    /// Normal review reads never repair scheduling. The generic legacy Card reader still has
    /// a normalization path; the notebook entrance deliberately uses its nonmutating read and
    /// fails explicitly instead of resetting a person's memory as a side effect of browsing.
    func requireValidBuiltInReviewCard(_ value: Card?) throws -> Card {
        guard let value, value.deletedAt == nil else { throw VocabularyError.editConflict }
        guard invalidFsrsStateReason(card: value) == nil else {
            throw LocalStoreError.validation("Saved exercise scheduling state is invalid")
        }
        return value
    }
}
