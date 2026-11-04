import Foundation
import LingroveNotebook

/// Card generation belongs to the same transaction as source/type changes. Stable membership
/// prevents regeneration from resetting memory or depending on a template's list position.
extension ReviewNoteStore {
    func reconcile(_ note: ReviewNote, type: ReviewNoteType, scope: LingroveNotebookSnapshot) throws {
        let store = self
        let lingroveNotebookReviewStore = LingroveNotebookReviewStore(core: core)
        let lingroveNotebookCardLinkStore = LingroveNotebookCardLinkStore(core: core)
        let members = try store.memberships(workspace: scope.workspaceId)
        let source = LingroveNotebookCardSource(workspaceId: scope.workspaceId, notebookId: scope.notebookId,
            entryId: note.entryID, senseId: note.senseID, exampleId: note.exampleID)
        let groups = try lingroveNotebookReviewStore.matching(source: source, snapshot: scope)
        var owner = try groups.first { $0.senseId == note.senseID } ?? lingroveNotebookReviewStore.insert(source: source, now: nowIsoTimestamp())
        for template in type.templates where template.enabled {
            if members.contains(where: { $0.noteID == note.id && $0.templateID == template.id }) { continue }
            let model = NotebookReviewNoteCard(note: note, noteType: type, templateID: template.id)
            guard let rendered = try? model.render(in: scope) else { continue }
            let input = try store.cardInput(rendered, note: note, scope: scope)
            if input.frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let cardID = LingroveNotebookCardMaterial.stableID("note-card|" + note.id.uuidString + "|" + template.id.uuidString,
                workspace: scope.workspaceId, sense: note.senseID).uuidString.lowercased()
            let linkID = LingroveNotebookCardMaterial.stableID("note-link|" + cardID, workspace: scope.workspaceId, sense: note.senseID)
            let now = nowIsoTimestamp()
            let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
            let operation = UUID().uuidString.lowercased()
            let card = try CardStore(core: core).saveCard(workspaceId: scope.workspaceId, input: input,
                initialMetadata: nil, cardId: nil, installationId: settings.installationId,
                operationId: operation, now: now, newCardID: cardID)
            try OutboxStore(core: core).enqueueCardUpsertOperation(workspaceId: scope.workspaceId,
                installationId: settings.installationId, operationId: operation, clientUpdatedAt: now,
                card: card, isInitialCreate: true, reviewScheduleImpact: true)
            let draft = LingroveNotebookCardDraft(id: linkID, source: source, sourceRevision: scope.revision, generatedContent: input)
            _ = try lingroveNotebookCardLinkStore.insert(draft: draft, cardId: cardID, generatedContent: input,
                fingerprint: LingroveNotebookCardMaterial.fingerprint(note), cardOperationId: card.lastOperationId, now: now)
            try lingroveNotebookCardLinkStore.holdCreatedCard(card, source: source, now: now)
            owner = try lingroveNotebookReviewStore.attach(cardId: cardID, linkId: linkID, to: owner, now: now)
            try store.attach(.init(noteID: note.id, templateID: template.id, cardID: cardID), workspace: scope.workspaceId)
        }
    }
}
