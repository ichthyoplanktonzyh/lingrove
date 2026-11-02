import Foundation
import LingroveNotebook

/// Preparation borrows the native Card writer and the same generation/revision fence as
/// corpus editing. One saved operation can change an example and faces without losing a
/// concurrent rating or transferring ownership to that example's current destination.
extension LingroveNotebookEngine {
    public func prepareNotebookExercise(link expected: LingroveNotebookCardLink, card baselineCard: Card,
        snapshot: LingroveNotebookSnapshot, exampleID: UUID?, input: CardEditorInput) throws {
        try Task.checkCancellation()
        try core.inTransaction {
            try requireCurrentNotebookCardLink(expected)
            let current = try lingroveNotebookStore.readSnapshot(workspaceId: snapshot.workspaceId)
            guard current == snapshot,
                  let card = try cardStore.loadOptionalCardIncludingDeleted(workspaceId: snapshot.workspaceId, cardId: expected.cardId),
                  card.lastOperationId == baselineCard.lastOperationId, card.deletedAt == nil else { throw VocabularyError.editConflict }
            let source = LingroveNotebookCardSource(workspaceId: expected.source.workspaceId, notebookId: expected.source.notebookId,
                entryId: expected.source.entryId, senseId: expected.source.senseId, exampleId: exampleID)
            guard let material = LingroveNotebookCardMaterial.resolve(source: source, snapshot: current) else { throw VocabularyError.editConflict }
            let settings = try workspaceSettingsStore.loadCloudSettings()
            let next = try persistCardMutation(workspaceId: current.workspaceId, input: input, initialMetadata: nil,
                cardId: card.cardId, cloudSettings: settings, now: nowIsoTimestamp())
            _ = try lingroveNotebookCardLinkStore.update(expected, generatedContent: material.content,
                sourceRevision: current.revision, source: source, allowingUnavailableMaterial: false, cardOperationId: next.lastOperationId)
            try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(current)
        }
    }

    public func retainNotebookExercise(link expected: LingroveNotebookCardLink, card baselineCard: Card, snapshot: LingroveNotebookSnapshot) throws {
        try core.inTransaction {
            try requireCurrentNotebookCardLink(expected)
            let current = try lingroveNotebookStore.readSnapshot(workspaceId: snapshot.workspaceId)
            let card = try loadActiveCard(workspaceId: snapshot.workspaceId, cardId: baselineCard.cardId)
            guard current == snapshot, card.lastOperationId == baselineCard.lastOperationId else { throw VocabularyError.editConflict }
            _ = try lingroveNotebookCardLinkStore.update(expected, generatedContent: nil, sourceRevision: current.revision, allowingUnavailableMaterial: true)
            try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(current)
        }
    }

    public func addNotebookExercise(_ draft: LingroveNotebookCardDraft) throws -> Card {
        try core.inTransaction {
            let snapshot = try lingroveNotebookCardLinkStore.validate(draft)
            let group = try lingroveNotebookReviewStore.matching(source: draft.source, snapshot: snapshot)
            guard !group.isEmpty else { throw VocabularyError.editConflict }
            // A replay must not resume an enrollment as a side effect. A new
            // exercise inherits the same resolved group state that UI presents.
            if let existing = try lingroveNotebookCardLinkStore.find(workspaceId: snapshot.workspaceId, id: draft.id) {
                return try cardStore.loadCard(workspaceId: snapshot.workspaceId, cardId: existing.cardId)
            }
            let status: LingroveNotebookReviewStatus = group.contains { $0.status == .active } ? .active : (group.contains { $0.status == .paused } ? .paused : .withdrawn)
            let owner = try group.first(where: { $0.senseId == draft.source.senseId })
                ?? lingroveNotebookReviewStore.insert(source: draft.source, now: nowIsoTimestamp())
            let enrollment = try lingroveNotebookReviewStore.update(owner, status: status)
            let card = try persistNewLingroveNotebookCard(draft: draft, input: draft.generatedContent,
                mediaAssetIdsReadyForUpload: [], validatedSnapshot: snapshot)
            _ = try lingroveNotebookReviewStore.attach(cardId: card.cardId, linkId: draft.id, to: enrollment, now: nowIsoTimestamp())
            try LingroveNotebookReviewMaterialStore(core: core).refreshInTransaction(snapshot)
            return card
        }
    }
}
