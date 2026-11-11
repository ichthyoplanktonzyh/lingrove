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
    func refreshInTransaction(_ scope: LingroveNotebookSnapshot, senseIDs: Set<UUID>? = nil) throws {
        let definitions = try types(workspace: scope.workspaceId)
        let admitted = Set(try memberships(workspace: scope.workspaceId).map(\.noteID))
        for note in try notes(scope: scope) where admitted.contains(note.id) && (senseIDs?.contains(note.senseID) ?? true) {
            guard let type = definitions.first(where: { $0.id == note.noteTypeID }) else { throw VocabularyError.invalidArchive }
            try reconcile(note, type: type, scope: scope)
        }
        for (cardID, model) in try cardModels(scope: scope) where senseIDs?.contains(model.note.senseID) ?? true {
            let source = try? NotebookReviewNoteCard.source(for: model.note, in: scope)
            try refreshCard(cardID, model: model, version: .init(scope), source: source)
        }
    }

    /// Both corpus edits and enrollment use this same material writer. The enrollment
    /// transaction already has its source and calls it only for the note it admitted.
    func refreshCard(_ cardID: String, model: NotebookReviewNoteCard, version: LingroveNotebookVersion,
                     source: (VocabularyEntry, VocabularySense)?) throws {
        let cards = CardStore(core: core), links = LingroveNotebookCardLinkStore(core: core)
        let workspace = version.workspaceId
        guard let card = try cards.loadOptionalCardIncludingDeleted(workspaceId: workspace, cardId: cardID),
              card.deletedAt == nil else { return }
        let input = try source.flatMap { entry, sense in
            let rendered = try? model.render(entry: entry, sense: sense)
            return try rendered.map { try cardInput($0, sense: sense, workspace: workspace) }
        }
        let ready = input.map { !$0.frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        try core.execute(sql: """
            INSERT INTO notebook_review_material_state(workspace_id,card_id,status) VALUES(?,?,?)
            ON CONFLICT(workspace_id,card_id) DO UPDATE SET status=excluded.status
            """, values: [.text(workspace), .text(cardID), .text(ready ? "ready" : "sourceMissing")])
        guard ready, let input, let link = try links.load(workspaceId: workspace, cardId: cardID).first else { return }
        let changed = card.frontText != input.frontText || card.backText != input.backText || card.tags != input.tags
        var operation: String?
        if changed {
            let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
            let now = nowIsoTimestamp(), id = UUID().uuidString.lowercased()
            let next = try cards.saveCard(workspaceId: workspace, input: input, initialMetadata: nil,
                cardId: cardID, installationId: settings.installationId, operationId: id, now: now)
            try OutboxStore(core: core).enqueueCardUpsertOperation(workspaceId: workspace,
                installationId: settings.installationId, operationId: id, clientUpdatedAt: now,
                card: next, isInitialCreate: false, reviewScheduleImpact: false)
            operation = id
        }
        if changed || link.sourceRevision != version.revision || link.source.exampleId != model.note.exampleID {
            let source = LingroveNotebookCardSource(workspaceId: link.source.workspaceId, notebookId: link.source.notebookId,
                entryId: link.source.entryId, senseId: link.source.senseId, exampleId: model.note.exampleID)
            _ = try links.update(link, generatedContent: input, sourceRevision: version.revision, source: source, cardOperationId: operation)
        }
    }

    func cardInput(_ rendered: ReviewRenderedCard, sense: VocabularySense, workspace: String) throws -> CardEditorInput {
        func face(_ html: String) throws -> String {
            var result = ReviewTemplateRenderer.plainText(html)
            for reference in VocabularyContentPolicy.images(sense.content ?? []) where html.contains(reference.filename) {
                let media = ReviewMaterialMediaReference(image: reference)
                let id = LingroveNotebookCardMaterial.mediaAssetID(reference: media, workspaceID: workspace)
                let bytes = try LingroveNotebookMediaStore(core: core).ownedImage(reference, workspaceId: workspace)
                try LingroveNotebookReviewMediaStore(core: core).insert(.init(reference: media, data: bytes), workspaceID: workspace)
                result += "\n\n![image](fcasset:" + id + ")"
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try .init(frontText: face(rendered.frontHTML), backText: face(rendered.backHTML), tags: sense.tags)
    }
}
