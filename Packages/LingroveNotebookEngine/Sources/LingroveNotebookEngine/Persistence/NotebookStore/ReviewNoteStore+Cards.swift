import Foundation
import LingroveNotebook

/// Card generation belongs to the same transaction as source/type changes. Stable membership
/// prevents regeneration from resetting memory or depending on a template's list position.
extension ReviewNoteStore {
    func reconcile(_ note: ReviewNote, type: ReviewNoteType, scope: LingroveNotebookSnapshot) throws {
        let (entry, sense) = try NotebookReviewNoteCard.source(for: note, in: scope)
        try reconcile(note, type: type, version: .init(scope), entry: entry, sense: sense)
    }

    func reconcile(_ note: ReviewNote, type: ReviewNoteType, version: LingroveNotebookVersion,
                   entry: VocabularyEntry, sense: VocabularySense) throws {
        let lingroveNotebookReviewStore = LingroveNotebookReviewStore(core: core)
        let lingroveNotebookCardLinkStore = LingroveNotebookCardLinkStore(core: core)
        let members = try memberships(workspace: version.workspaceId, noteID: note.id)
        let source = LingroveNotebookCardSource(workspaceId: version.workspaceId, notebookId: version.notebookId,
            entryId: note.entryID, senseId: note.senseID, exampleId: note.exampleID)
        let groups = try lingroveNotebookReviewStore.load(workspaceId: version.workspaceId,
            notebookId: version.notebookId, senseIDs: [note.senseID])
        var owner = try groups.first ?? lingroveNotebookReviewStore.insert(source: source, now: nowIsoTimestamp())
        for template in type.templates where template.enabled {
            if members.contains(where: { $0.noteID == note.id && $0.templateID == template.id }) { continue }
            let model = NotebookReviewNoteCard(note: note, noteType: type, templateID: template.id)
            guard let rendered = try? model.render(entry: entry, sense: sense) else { continue }
            let input = try cardInput(rendered, sense: sense, workspace: version.workspaceId)
            if input.frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let cardID = LingroveNotebookCardMaterial.stableID("note-card|" + note.id.uuidString + "|" + template.id.uuidString,
                workspace: version.workspaceId, sense: note.senseID).uuidString.lowercased()
            let linkID = LingroveNotebookCardMaterial.stableID("note-link|" + cardID, workspace: version.workspaceId, sense: note.senseID)
            let now = nowIsoTimestamp()
            let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
            let operation = UUID().uuidString.lowercased()
            let card = try CardStore(core: core).saveCard(workspaceId: version.workspaceId, input: input,
                initialMetadata: nil, cardId: nil, installationId: settings.installationId,
                operationId: operation, now: now, newCardID: cardID)
            try OutboxStore(core: core).enqueueCardUpsertOperation(workspaceId: version.workspaceId,
                installationId: settings.installationId, operationId: operation, clientUpdatedAt: now,
                card: card, isInitialCreate: true, reviewScheduleImpact: true)
            let draft = LingroveNotebookCardDraft(id: linkID, source: source, sourceRevision: version.revision, generatedContent: input)
            _ = try lingroveNotebookCardLinkStore.insert(draft: draft, cardId: cardID, generatedContent: input,
                fingerprint: LingroveNotebookCardMaterial.fingerprint(note), cardOperationId: card.lastOperationId, now: now)
            try lingroveNotebookCardLinkStore.holdCreatedCard(card, source: source, now: now)
            owner = try lingroveNotebookReviewStore.attach(cardId: cardID, linkId: linkID, to: owner, now: now)
            try attach(.init(noteID: note.id, templateID: template.id, cardID: cardID), workspace: version.workspaceId)
        }
    }
}
