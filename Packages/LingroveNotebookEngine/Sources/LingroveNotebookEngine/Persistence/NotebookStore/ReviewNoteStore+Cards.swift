import Foundation
import LingroveNotebook

/// Card generation belongs to the same transaction as source/type changes. Stable membership
/// prevents regeneration from resetting memory or depending on a template's list position.
extension ReviewNoteStore {
    @discardableResult
    func reconcile(_ note: ReviewNote, type: ReviewNoteType, scope: LingroveNotebookSnapshot) throws -> [Membership] {
        let (entry, sense) = try NotebookReviewNoteCard.source(for: note, in: scope)
        return try reconcile(note, type: type, version: .init(scope), entry: entry, sense: sense)
    }

    @discardableResult
    func reconcile(_ note: ReviewNote, type: ReviewNoteType, version: LingroveNotebookVersion,
                   entry: VocabularyEntry, sense: VocabularySense, knownMembers: [Membership]? = nil,
                   prepared: ReviewTemplateRenderer.Prepared? = nil) throws -> [Membership] {
        let lingroveNotebookReviewStore = LingroveNotebookReviewStore(core: core)
        let lingroveNotebookCardLinkStore = LingroveNotebookCardLinkStore(core: core)
        var members = try knownMembers ?? memberships(workspace: version.workspaceId, noteID: note.id)
        let source = LingroveNotebookCardSource(workspaceId: version.workspaceId, notebookId: version.notebookId,
            entryId: note.entryID, senseId: note.senseID, exampleId: note.exampleID)
        let groups = try lingroveNotebookReviewStore.load(workspaceId: version.workspaceId,
            notebookId: version.notebookId, senseIDs: [note.senseID])
        var owner = try groups.first ?? lingroveNotebookReviewStore.insert(source: source, now: nowIsoTimestamp())
        for template in type.templates where template.enabled {
            if members.contains(where: { $0.noteID == note.id && $0.templateID == template.id }) { continue }
            let model = NotebookReviewNoteCard(note: note, noteType: type, templateID: template.id)
            guard let rendered = try? model.render(entry: entry, sense: sense, using: prepared) else { continue }
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
            let draft = ReviewNoteCardLinkDraft(id: linkID, source: source, sourceRevision: version.revision, generatedContent: input)
            _ = try lingroveNotebookCardLinkStore.insert(draft: draft, cardId: cardID,
                fingerprint: LingroveNotebookCardMaterial.fingerprint(note), cardOperationId: card.lastOperationId, now: now)
            try lingroveNotebookCardLinkStore.holdCreatedCard(card, source: source, now: now)
            owner = try lingroveNotebookReviewStore.attach(cardId: cardID, linkId: linkID, to: owner, now: now)
            let member = Membership(noteID: note.id, templateID: template.id, cardID: cardID)
            try attach(member, workspace: version.workspaceId)
            members.append(member)
        }
        return members
    }
}
