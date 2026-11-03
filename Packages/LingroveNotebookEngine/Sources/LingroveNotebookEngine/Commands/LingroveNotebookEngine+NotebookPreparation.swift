import Foundation
import LingroveNotebook

/// Preparation borrows the native Card writer and the same generation/revision fence as
/// corpus editing. One saved operation can change an example and faces without losing a
/// concurrent rating or transferring ownership to that example's current destination.
extension LingroveNotebookEngine {
    public func prepareNotebookExercise(link expected: LingroveNotebookCardLink, card baselineCard: Card,
        snapshot: LingroveNotebookSnapshot, exampleID: UUID?, input: CardEditorInput,
        materialPlan: ReviewMaterialPlan? = nil, media: [ReviewMaterialPreparedMedia] = [],
        action: NotebookBuiltInReviewAction? = nil) throws {
        try Task.checkCancellation()
        try core.inTransaction {
            if let action { try requireBuiltInReviewActionInTransaction(action) }
            try requireCurrentNotebookCardLink(expected)
            let current = try lingroveNotebookStore.readSnapshot(workspaceId: snapshot.workspaceId)
            guard current == snapshot,
                  let card = try cardStore.loadOptionalCardIncludingDeleted(workspaceId: snapshot.workspaceId, cardId: expected.cardId),
                  card.lastOperationId == baselineCard.lastOperationId, card.deletedAt == nil else { throw VocabularyError.editConflict }
            let source = LingroveNotebookCardSource(workspaceId: expected.source.workspaceId, notebookId: expected.source.notebookId,
                entryId: expected.source.entryId, senseId: expected.source.senseId, exampleId: exampleID)
            var plan = materialPlan ?? expected.materialPlan
            plan?.exampleID = exampleID
            guard let material = LingroveNotebookCardMaterial.resolve(source: source, snapshot: current, materialPlan: plan) else { throw VocabularyError.editConflict }
            try LingroveNotebookReviewMediaStore(core: core).register(plan: plan, source: source, snapshot: current, supplied: media)
            try Task.checkCancellation()
            let settings = try workspaceSettingsStore.loadCloudSettings()
            let next = try persistCardMutation(workspaceId: current.workspaceId, input: input, initialMetadata: nil,
                cardId: card.cardId, cloudSettings: settings, now: nowIsoTimestamp())
            _ = try lingroveNotebookCardLinkStore.update(expected, generatedContent: material.content,
                sourceRevision: current.revision, source: source, allowingUnavailableMaterial: false, materialPlan: plan, cardOperationId: next.lastOperationId)
            try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(current)
        }
    }

    public func retainNotebookExercise(link expected: LingroveNotebookCardLink, card baselineCard: Card,
        snapshot: LingroveNotebookSnapshot, action: NotebookBuiltInReviewAction? = nil) throws {
        try core.inTransaction {
            try Task.checkCancellation()
            if let action { try requireBuiltInReviewActionInTransaction(action) }
            try requireCurrentNotebookCardLink(expected)
            let current = try lingroveNotebookStore.readSnapshot(workspaceId: snapshot.workspaceId)
            let card = try loadActiveCard(workspaceId: snapshot.workspaceId, cardId: baselineCard.cardId)
            guard current == snapshot, card.lastOperationId == baselineCard.lastOperationId else { throw VocabularyError.editConflict }
            // Retention grants use while the source is missing; it does not transfer ownership
            // of every field to the user. Keep the baseline for three-way refresh on source return.
            _ = try lingroveNotebookCardLinkStore.update(expected, generatedContent: expected.generatedContent,
                sourceRevision: current.revision, allowingUnavailableMaterial: true)
            try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(current)
        }
    }

    public func addNotebookExercise(_ draft: LingroveNotebookCardDraft, scope: LingroveNotebookSnapshot? = nil,
        input: CardEditorInput? = nil, media: [ReviewMaterialPreparedMedia] = [], action: NotebookBuiltInReviewAction? = nil) throws -> Card {
        try core.inTransaction {
            try Task.checkCancellation()
            if let scope { try requireCurrentScopeInTransaction(scope, requireRevision: true) }
            if let action { try requireCurrentScopeInTransaction(action.scope, requireRevision: true) }
            let snapshot = try lingroveNotebookCardLinkStore.validate(draft)
            let group = try lingroveNotebookReviewStore.matching(source: draft.source, snapshot: snapshot)
            guard !group.isEmpty else { throw VocabularyError.editConflict }
            // A replay must not resume an enrollment as a side effect. A new
            // exercise inherits the same resolved group state that UI presents.
            if try lingroveNotebookCardLinkStore.find(workspaceId: snapshot.workspaceId, id: draft.id) != nil {
                return try persistNewLingroveNotebookCard(draft: draft, input: input ?? draft.generatedContent,
                    mediaAssetIdsReadyForUpload: [], validatedSnapshot: snapshot, media: media)
            }
            if let action { try requireBuiltInReviewActionInTransaction(action) }
            let status: LingroveNotebookReviewStatus = group.contains { $0.status == .active } ? .active : (group.contains { $0.status == .paused } ? .paused : .withdrawn)
            let owner = try group.first(where: { $0.senseId == draft.source.senseId })
                ?? lingroveNotebookReviewStore.insert(source: draft.source, now: nowIsoTimestamp())
            let enrollment = try lingroveNotebookReviewStore.update(owner, status: status)
            let card = try persistNewLingroveNotebookCard(draft: draft, input: input ?? draft.generatedContent,
                mediaAssetIdsReadyForUpload: [], validatedSnapshot: snapshot, media: media)
            _ = try lingroveNotebookReviewStore.attach(cardId: card.cardId, linkId: draft.id, to: enrollment, now: nowIsoTimestamp())
            try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(snapshot)
            return card
        }
    }
}
