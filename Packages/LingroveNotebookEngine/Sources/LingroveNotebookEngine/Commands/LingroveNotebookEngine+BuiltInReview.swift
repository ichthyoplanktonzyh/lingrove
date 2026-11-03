import Foundation
import LingroveNotebook

/// Nonoptional saved-action entry points for the native Mac window. They compose existing
/// writers rather than nesting transactions or inventing a second rating/undo implementation.
extension LingroveNotebookEngine {
    @discardableResult
    public func enrollBuiltInNotebookSense(_ draft: LingroveNotebookCardDraft, input: CardEditorInput,
                                          media: [ReviewMaterialPreparedMedia] = [], action: NotebookBuiltInReviewAction) throws -> [LingroveNotebookReviewEnrollment] {
        guard action.cards.isEmpty, draft.source.senseId == action.selection.senseID,
              action.scope.document.collectedEntries.contains(where: { entry in
                  entry.id == action.selection.entryID && entry.senses.contains { $0.id == action.selection.senseID }
              }) else { throw VocabularyError.editConflict }
        return try enrollLingroveNotebookSenses([draft], scope: action.scope,
            preparedInputs: [draft.id: input], media: media, action: action)
    }

    /// A native multi-selection freezes one action per sense. The shared batch validates all
    /// actions under one writer lock and commits all enrollments or none; intent IDs survive retry.
    @discardableResult
    public func enrollBuiltInNotebookSenses(_ drafts: [LingroveNotebookCardDraft], inputs: [UUID: CardEditorInput],
                                           media: [ReviewMaterialPreparedMedia] = [],
                                           actions: [NotebookBuiltInReviewAction]) throws -> [LingroveNotebookReviewEnrollment] {
        guard let first = actions.first, actions.count == drafts.count,
              Set(actions.map { $0.selection.senseID }).count == actions.count,
              drafts.allSatisfy({ draft in actions.contains { $0.selection.senseID == draft.source.senseId } }),
              actions.allSatisfy({ $0.scope == first.scope }) else { throw VocabularyError.editConflict }
        return try enrollLingroveNotebookSenses(drafts, scope: first.scope, preparedInputs: inputs,
            media: media, actions: actions)
    }

    public func addBuiltInNotebookExercise(_ draft: LingroveNotebookCardDraft, input: CardEditorInput,
                                          media: [ReviewMaterialPreparedMedia] = [], action: NotebookBuiltInReviewAction) throws -> Card {
        guard draft.source.senseId == action.selection.senseID else { throw VocabularyError.editConflict }
        return try addNotebookExercise(draft, scope: action.scope, input: input, media: media, action: action)
    }

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
        let current = try lingroveNotebookStore.readSnapshot(workspaceId: action.scope.workspaceId)
        let enrollmentIDs = Set(action.enrollments.map(\.id))
        let matching = try lingroveNotebookReviewStore.load(workspaceId: current.workspaceId).filter { enrollment in
            guard enrollment.notebookId == current.notebookId else { return false }
            if let resolved = LingroveNotebookCardMaterial.resolvedSelection(source: enrollment.source, snapshot: current) {
                return resolved == action.selection
            }
            return enrollmentIDs.contains(enrollment.id)
        }
        guard Set(matching) == Set(action.enrollments),
              try workspaceSettingsStore.loadWorkspaceSchedulerSettings(workspaceId: current.workspaceId) == action.schedulerSettings
        else { throw VocabularyError.editConflict }
        for card in action.cards {
            let stored = try cardStore.loadOptionalCardIncludingDeleted(workspaceId: current.workspaceId, cardId: card.cardId)
            guard try requireValidBuiltInReviewCard(stored) == card else {
                throw VocabularyError.editConflict
            }
        }
        let cardIDs = Set(action.cards.map(\.cardId))
        let currentLinks = try lingroveNotebookCardLinkStore.load(workspaceId: current.workspaceId)
            .filter { cardIDs.contains($0.cardId) }
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

    /// An unavailable source can still have explicitly retained, authored practice material.
    /// This uses the same native Card writer; keeping its old generated baseline means a later
    /// returning source follows untouched fields and continues to respect manual ownership.
    public func saveRetainedBuiltInNotebookMaterial(link: LingroveNotebookCardLink, card: Card,
                                                   input: CardEditorInput, materialPlan: ReviewMaterialPlan? = nil,
                                                   media: [ReviewMaterialPreparedMedia] = [], action: NotebookBuiltInReviewAction) throws {
        try core.inTransaction {
            try Task.checkCancellation()
            try requireBuiltInReviewActionInTransaction(action)
            try requireCurrentNotebookCardLink(link)
            guard link.cardId == card.cardId, link.allowsUnavailableMaterial, action.cards.contains(card) else {
                throw VocabularyError.editConflict
            }
            let plan = materialPlan ?? link.materialPlan
            try LingroveNotebookReviewMediaStore(core: core).register(plan: plan, source: link.source, snapshot: action.scope, supplied: media)
            try Task.checkCancellation()
            let next = try persistCardMutation(workspaceId: action.scope.workspaceId, input: input,
                initialMetadata: nil, cardId: card.cardId, cloudSettings: workspaceSettingsStore.loadCloudSettings(),
                now: nowIsoTimestamp())
            _ = try lingroveNotebookCardLinkStore.update(link, generatedContent: link.generatedContent,
                sourceRevision: action.scope.revision, materialPlan: plan, cardOperationId: next.lastOperationId)
        }
    }
}
