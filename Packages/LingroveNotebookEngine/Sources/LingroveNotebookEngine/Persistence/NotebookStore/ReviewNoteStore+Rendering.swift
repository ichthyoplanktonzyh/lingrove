import Foundation
import LingroveNotebook

extension ReviewNoteStore {
    public func cardModels(scope: LingroveNotebookSnapshot) throws -> [String: NotebookReviewNoteCard] {
        let notes = Dictionary(uniqueKeysWithValues: try notes(scope: scope).map { ($0.id, $0) })
        let types = Dictionary(uniqueKeysWithValues: try types(workspace: scope.workspaceId).map { ($0.id, $0) })
        var result: [String: NotebookReviewNoteCard] = [:]
        for member in try memberships(workspace: scope.workspaceId) {
            guard let note = notes[member.noteID], let type = types[note.noteTypeID] else { throw VocabularyError.invalidArchive }
            result[member.cardID] = .init(note: note, noteType: type, templateID: member.templateID)
        }
        return result
    }

    /// Updates render caches only. Note/template definitions remain authoritative and the
    /// existing CardStore keeps FSRS/reps/events when replacing its readable face projection.
    func refreshInTransaction(_ scope: LingroveNotebookSnapshot) throws {
        let definitions = try types(workspace: scope.workspaceId)
        let admitted = Set(try memberships(workspace: scope.workspaceId).map(\.noteID))
        for note in try notes(scope: scope) where admitted.contains(note.id) {
            guard let type = definitions.first(where: { $0.id == note.noteTypeID }) else { throw VocabularyError.invalidArchive }
            try reconcile(note, type: type, scope: scope)
        }
        let cards = CardStore(core: core), links = LingroveNotebookCardLinkStore(core: core)
        let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
        for (cardID, model) in try cardModels(scope: scope) {
            guard let card = try cards.loadOptionalCardIncludingDeleted(workspaceId: scope.workspaceId, cardId: cardID), card.deletedAt == nil else { continue }
            let rendered = try? model.render(in: scope)
            let input = try rendered.map { try cardInput($0, note: model.note, scope: scope) }
            let ready = input.map { !$0.frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            try core.execute(sql: "INSERT INTO notebook_review_material_state(workspace_id,card_id,status) VALUES(?,?,?) ON CONFLICT(workspace_id,card_id) DO UPDATE SET status=excluded.status",
                values: [.text(scope.workspaceId), .text(cardID), .text(ready ? "ready" : "sourceMissing")])
            guard ready, let input, let link = try links.load(workspaceId: scope.workspaceId, cardId: cardID).first else { continue }
            let changed = card.frontText != input.frontText || card.backText != input.backText || card.tags != input.tags
            var operation: String?
            if changed {
                let now = nowIsoTimestamp(), id = UUID().uuidString.lowercased()
                let next = try cards.saveCard(workspaceId: scope.workspaceId, input: input, initialMetadata: nil,
                    cardId: cardID, installationId: settings.installationId, operationId: id, now: now)
                try OutboxStore(core: core).enqueueCardUpsertOperation(workspaceId: scope.workspaceId,
                    installationId: settings.installationId, operationId: id, clientUpdatedAt: now,
                    card: next, isInitialCreate: false, reviewScheduleImpact: false)
                operation = id
            }
            if changed || link.sourceRevision != scope.revision || link.source.exampleId != model.note.exampleID {
                let source = LingroveNotebookCardSource(workspaceId: link.source.workspaceId, notebookId: link.source.notebookId,
                    entryId: link.source.entryId, senseId: link.source.senseId, exampleId: model.note.exampleID)
                _ = try links.update(link, generatedContent: input, sourceRevision: scope.revision, source: source, cardOperationId: operation)
            }
        }
    }

    func cardInput(_ rendered: ReviewRenderedCard, note: ReviewNote, scope: LingroveNotebookSnapshot) throws -> CardEditorInput {
        guard let entry = scope.document.entries.first(where: { $0.senses.contains { $0.id == note.senseID || $0.mergedFrom.contains(note.senseID) } }),
              let sense = entry.senses.first(where: { $0.id == note.senseID || $0.mergedFrom.contains(note.senseID) }) else {
            throw ReviewTemplateError.sourceUnavailable
        }
        func face(_ html: String) throws -> String {
            var result = ReviewTemplateRenderer.plainText(html)
            for reference in VocabularyContentPolicy.images(sense.content ?? []) where html.contains(reference.filename) {
                let media = ReviewMaterialMediaReference(image: reference)
                let id = LingroveNotebookCardMaterial.mediaAssetID(reference: media, workspaceID: scope.workspaceId)
                let bytes = try LingroveNotebookMediaStore(core: core).ownedImage(reference, workspaceId: scope.workspaceId)
                try LingroveNotebookReviewMediaStore(core: core).insert(.init(reference: media, data: bytes), workspaceID: scope.workspaceId)
                result += "\n\n![image](fcasset:" + id + ")"
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try .init(frontText: face(rendered.frontHTML), backText: face(rendered.backHTML), tags: sense.tags)
    }
}
