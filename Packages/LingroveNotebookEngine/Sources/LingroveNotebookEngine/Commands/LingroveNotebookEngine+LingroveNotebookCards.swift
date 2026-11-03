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

    public func saveNewLingroveNotebookCard(
        draft: LingroveNotebookCardDraft, input: CardEditorInput, mediaAssetIdsReadyForUpload: Set<String>,
        media: [ReviewMaterialPreparedMedia] = []
    ) throws -> Card {
        try Task.checkCancellation()
        return try self.core.inTransaction {
            try Task.checkCancellation()
            return try self.persistNewLingroveNotebookCard(draft: draft, input: input,
                mediaAssetIdsReadyForUpload: mediaAssetIdsReadyForUpload, media: media)
        }
    }

    /// Enrollment composes this writer with its own records inside the same transaction.
    /// A separate helper avoids nested BEGINs while keeping the public save boundary atomic.
    public func persistNewLingroveNotebookCard(
        draft: LingroveNotebookCardDraft, input: CardEditorInput, mediaAssetIdsReadyForUpload: Set<String>,
        validatedSnapshot: LingroveNotebookSnapshot? = nil, newCardID: String? = nil, media: [ReviewMaterialPreparedMedia] = []
    ) throws -> Card {
        try self.cardStore.validateCardInput(input: input)
        let normalized = LingroveNotebookCardMaterial.normalized(input)
        let fingerprint = try self.notebookCardCreationFingerprint(draft: draft, input: normalized, cardId: nil,
            mediaAssetIds: mediaAssetIdsReadyForUpload)
        try self.lingroveNotebookCardLinkStore.requireActiveScope(draft.source)
        if let prior = try self.lingroveNotebookCardLinkStore.find(workspaceId: draft.source.workspaceId, id: draft.id) {
            guard prior.creationFingerprint == fingerprint else { throw VocabularyError.editConflict }
            // Returning the current Card preserves edits/reviews/deletion that followed the
            // first commit. A replay never rewrites that Card from an obsolete creation draft.
            guard let card = try self.cardStore.loadOptionalCardIncludingDeleted(
                workspaceId: prior.source.workspaceId, cardId: prior.cardId
            ) else { throw LocalStoreError.notFound("Card not found") }
            return card
        }
        let snapshot: LingroveNotebookSnapshot
        if let validatedSnapshot {
            snapshot = validatedSnapshot
            // Only compound writers supply a snapshot read under their current writer lock.
            // This still validates exact source/projection, without decoding the book per Card.
            try self.lingroveNotebookCardLinkStore.validate(draft, against: validatedSnapshot)
        } else {
            snapshot = try self.lingroveNotebookCardLinkStore.validate(draft)
        }
        try LingroveNotebookReviewMediaStore(core: core).register(plan: draft.materialPlan, source: draft.source,
            snapshot: snapshot, supplied: media)
        try Task.checkCancellation()
        let now = nowIsoTimestamp()
        let settings = try self.workspaceSettingsStore.loadCloudSettings()
        let card = try self.persistCardMutation(workspaceId: draft.source.workspaceId, input: normalized,
            initialMetadata: nil, cardId: nil, cloudSettings: settings, now: now, newCardID: newCardID)
        _ = try self.lingroveNotebookCardLinkStore.insert(draft: draft, cardId: card.cardId,
            generatedContent: draft.generatedContent, fingerprint: fingerprint, cardOperationId: card.lastOperationId, now: now)
        try self.lingroveNotebookCardLinkStore.holdCreatedCard(card, source: draft.source, now: now)
        // Managed media is already local. Its upload, like this Card and its reviews, waits
        // for the notebook-capable consumer; the legacy media queue must not publish it first.
        return card
    }

    public func linkLingroveNotebookCard(_ draft: LingroveNotebookCardDraft, cardId: String,
                                         media: [ReviewMaterialPreparedMedia] = []) throws -> LingroveNotebookCardLink {
        try Task.checkCancellation()
        let fingerprint = try self.notebookCardCreationFingerprint(draft: draft, input: nil, cardId: cardId, mediaAssetIds: [])
        return try self.core.inTransaction {
            try Task.checkCancellation()
            try self.lingroveNotebookCardLinkStore.requireActiveScope(draft.source)
            if let prior = try self.lingroveNotebookCardLinkStore.find(workspaceId: draft.source.workspaceId, id: draft.id) {
                guard prior.creationFingerprint == fingerprint else { throw VocabularyError.editConflict }
                return prior
            }
            let snapshot = try self.lingroveNotebookCardLinkStore.validate(draft)
            _ = try self.loadActiveCard(workspaceId: draft.source.workspaceId, cardId: cardId)
            try Task.checkCancellation()
            let destination = LingroveNotebookCardMaterial.resolvedSelection(source: draft.source, snapshot: snapshot)
            // A merge/move can give an already linked source a new current destination. Compare
            // resolved identities too, so associating the same existing exercise remains a no-op.
            for existing in try self.lingroveNotebookCardLinkStore.load(workspaceId: draft.source.workspaceId, cardId: cardId) {
                if let resolved = LingroveNotebookCardMaterial.resolvedSelection(source: existing.source, snapshot: snapshot),
                   resolved == destination {
                    return existing
                }
            }
            try LingroveNotebookReviewMediaStore(core: core).register(plan: draft.materialPlan, source: draft.source,
                snapshot: snapshot, supplied: media)
            try Task.checkCancellation()
            return try self.lingroveNotebookCardLinkStore.insert(draft: draft, cardId: cardId, generatedContent: nil,
                fingerprint: fingerprint, cardOperationId: nil, now: nowIsoTimestamp())
        }
    }

    public func refreshLingroveNotebookCard(
        _ expected: LingroveNotebookCardLink, basedOn baseline: LingroveNotebookSnapshot,
        replacingManualContent: Bool = false
    ) throws -> Card {
        try Task.checkCancellation()
        return try self.core.inTransaction {
            try Task.checkCancellation()
            try self.requireCurrentNotebookCardLink(expected)
            let current = try self.lingroveNotebookStore.readSnapshot(workspaceId: expected.source.workspaceId)
            guard current.notebookId == baseline.notebookId, current.workspaceId == baseline.workspaceId,
                  current.revision == baseline.revision, current.generation == baseline.generation,
                  let material = LingroveNotebookCardMaterial.resolve(source: expected.source, snapshot: current, materialPlan: expected.materialPlan) else {
                throw VocabularyError.editConflict
            }
            let original = try self.loadActiveCard(workspaceId: expected.source.workspaceId, cardId: expected.cardId)
            let content = CardEditorInput(frontText: original.frontText, backText: original.backText, tags: original.tags)
            let proposed = LingroveNotebookCardMaterial.refreshed(current: content, previous: expected.generatedContent,
                latest: material.content, replacingManualContent: replacingManualContent)
            let nextGenerated: CardEditorInput? = expected.generatedContent == nil && !replacingManualContent ? nil : material.content
            let changesCard = !LingroveNotebookCardMaterial.sameStoredBytes(content, proposed)
            if !changesCard, expected.sourceRevision == current.revision,
               LingroveNotebookCardMaterial.sameStoredBytes(expected.generatedContent, nextGenerated) {
                return original
            }
            let card: Card
            if changesCard {
                let settings = try self.workspaceSettingsStore.loadCloudSettings()
                card = try self.persistCardMutation(workspaceId: expected.source.workspaceId, input: proposed,
                    initialMetadata: nil, cardId: original.cardId, cloudSettings: settings, now: nowIsoTimestamp())
            } else { card = original }
            _ = try self.lingroveNotebookCardLinkStore.update(expected, generatedContent: nextGenerated,
                sourceRevision: current.revision, cardOperationId: changesCard ? card.lastOperationId : nil)
            return card
        }
    }

    @discardableResult
    public func unlinkLingroveNotebookCard(_ expected: LingroveNotebookCardLink) throws -> LingroveNotebookCardLink {
        try Task.checkCancellation()
        return try self.core.inTransaction {
            try Task.checkCancellation()
            try self.lingroveNotebookCardLinkStore.requireActiveScope(expected.source)
            if let current = try self.lingroveNotebookCardLinkStore.find(workspaceId: expected.source.workspaceId, id: expected.id),
               current.deletedAt != nil { return current }
            try self.requireCurrentNotebookCardLink(expected)
            return try self.lingroveNotebookCardLinkStore.update(expected, generatedContent: expected.generatedContent,
                sourceRevision: expected.sourceRevision, deleting: true)
        }
    }

    public func requireCurrentNotebookCardLink(_ expected: LingroveNotebookCardLink) throws {
        try self.lingroveNotebookCardLinkStore.requireActiveScope(expected.source)
        guard try self.lingroveNotebookCardLinkStore.find(workspaceId: expected.source.workspaceId, id: expected.id) == expected,
              expected.deletedAt == nil else { throw VocabularyError.editConflict }
    }

    private func notebookCardCreationFingerprint(
        draft: LingroveNotebookCardDraft, input: CardEditorInput?, cardId: String?, mediaAssetIds: Set<String>
    ) throws -> String {
        try LingroveNotebookCardMaterial.fingerprint(NotebookCardCreationIdentity(source: draft.source,
            sourceRevision: draft.sourceRevision, generated: draft.generatedContent, materialPlan: draft.materialPlan, input: input,
            cardId: cardId, mediaAssetIds: mediaAssetIds.sorted()))
    }
}

/// Idempotency compares the immutable request, not the Card's later mutable fields. Kept private
/// to persistence so callers never need to assemble a journal payload themselves.
private struct NotebookCardCreationIdentity: Encodable {
    let source: LingroveNotebookCardSource
    let sourceRevision: UInt64
    let generated: CardEditorInput
    let materialPlan: ReviewMaterialPlan?
    let input: CardEditorInput?
    let cardId: String?
    let mediaAssetIds: [String]
}
