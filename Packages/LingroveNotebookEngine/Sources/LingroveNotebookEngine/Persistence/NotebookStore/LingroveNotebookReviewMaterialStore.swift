import Foundation
import LingroveNotebook

/// Notebook writers invoke this adapter inside their existing transaction, after replacing
/// source rows. It projects only faces/tags; the Card's FSRS fields and append-only events are
/// never touched. Missing evidence is persisted as queue admission state, not guessed at read.
public struct LingroveNotebookReviewMaterialStore {
    public let core: DatabaseCore

    public func refreshInTransaction(_ snapshot: LingroveNotebookSnapshot, senseIDs: Set<UUID>? = nil,
                                     entries: [VocabularyEntry]? = nil) throws {
        guard senseIDs?.isEmpty != true else { return }
        let links = LingroveNotebookCardLinkStore(core: core)
        let cards = CardStore(core: core)
        let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
        let selectedLinks = try senseIDs.map { try links.load(workspaceId: snapshot.workspaceId, senseIDs: $0) }
            ?? links.load(workspaceId: snapshot.workspaceId)
        let noteCards = try ReviewNoteStore(core: core).ownedCardIDs(workspace: snapshot.workspaceId,
            cardIDs: Set(selectedLinks.map(\.cardId)))
        // Narrow entry transactions already know which live and historical senses changed.
        // Other links keep their previous material revision and need no new render or journal.
        for link in selectedLinks {
            if noteCards.contains(link.cardId) { continue }
            guard let card = try cards.loadOptionalCardIncludingDeleted(workspaceId: snapshot.workspaceId, cardId: link.cardId), card.deletedAt == nil else { continue }
            let material = LingroveNotebookCardMaterial.resolve(source: link.source, snapshot: snapshot, materialPlan: link.materialPlan)
            let state = material == nil && link.allowsUnavailableMaterial ? "retained" : material == nil ? (LingroveNotebookCardMaterial.resolvedSelection(source: link.source, snapshot: snapshot) == nil ? "sourceMissing" : "exampleMissing") : "ready"
            try setStatus(state, cardID: card.cardId, workspace: snapshot.workspaceId)
            guard let material else { continue }
            try LingroveNotebookReviewMediaStore(core: core).register(plan: link.materialPlan, source: link.source, snapshot: snapshot, supplied: [])
            let current = CardEditorInput(frontText: card.frontText, backText: card.backText, tags: card.tags)
            let proposed = LingroveNotebookCardMaterial.refreshed(current: current, previous: link.generatedContent, latest: material.content)
            let generated = link.generatedContent == nil ? nil : material.content
            let changesCard = !LingroveNotebookCardMaterial.sameStoredBytes(current, proposed)
            guard changesCard || !LingroveNotebookCardMaterial.sameStoredBytes(link.generatedContent, generated)
                    || link.sourceRevision != snapshot.revision else { continue }
            var operationID: String?
            if changesCard {
                let now = nowIsoTimestamp(), id = UUID().uuidString.lowercased()
                let next = try cards.saveCard(workspaceId: card.workspaceId, input: proposed, initialMetadata: nil,
                    cardId: card.cardId, installationId: settings.installationId, operationId: id, now: now)
                try OutboxStore(core: core).enqueueCardUpsertOperation(workspaceId: card.workspaceId,
                    installationId: settings.installationId, operationId: id, clientUpdatedAt: now,
                    card: next, isInitialCreate: false, reviewScheduleImpact: false)
                operationID = id
            }
            _ = try links.update(link, generatedContent: generated, sourceRevision: snapshot.revision, cardOperationId: operationID)
        }
        try ReviewNoteStore(core: core).refreshInTransaction(snapshot, senseIDs: senseIDs, entries: entries)
    }

    /// The certified local writer supplies only IDs it just retired, including merged aliases.
    /// No live source remains for these IDs, so sourceMissing/retained is the complete refresh:
    /// no face rendering, new template members, Card writes or event changes are necessary.
    /// This adapter borrows that writer's transaction; it never accepts arbitrary UI drafts or
    /// constructs a partial snapshot. Other sources and other notebook lifetimes stay untouched.
    func retireSourcesInTransaction(version: LingroveNotebookVersion, senseIDs: Set<UUID>) throws {
        guard !senseIDs.isEmpty else { return }
        let notes = ReviewNoteStore(core: core)
        let selectedLinks = try LingroveNotebookCardLinkStore(core: core).load(workspaceId: version.workspaceId,
            notebookId: version.notebookId, senseIDs: senseIDs)
        let noteCards = try notes.ownedCardIDs(workspace: version.workspaceId, cardIDs: Set(selectedLinks.map(\.cardId)))
        let cards = CardStore(core: core)
        for link in selectedLinks where !noteCards.contains(link.cardId) {
            try Task.checkCancellation()
            guard let card = try cards.loadOptionalCardIncludingDeleted(workspaceId: version.workspaceId, cardId: link.cardId),
                  card.deletedAt == nil else { continue }
            // Explicitly retained legacy exercises may use their saved faces after source
            // retirement. Shared Notes keep their existing sourceMissing rule below.
            try setStatus(link.allowsUnavailableMaterial ? "retained" : "sourceMissing",
                cardID: card.cardId, workspace: version.workspaceId)
        }
        let selectedNotes = try notes.notes(version: version, senseIDs: senseIDs)
        let members = try notes.memberships(workspace: version.workspaceId, noteIDs: Set(selectedNotes.map(\.id)))
        // Validate only definitions belonging to the affected members. A malformed/missing
        // type must still fail atomically; unrelated Notes/types do not enter this command.
        let models = try notes.cardModels(version: version, cardIDs: Set(members.map(\.cardID)))
        for member in members {
            try Task.checkCancellation()
            guard let model = models[member.cardID] else { throw VocabularyError.invalidArchive }
            try notes.refreshCard(member.cardID, model: model, version: version, source: nil)
        }
    }

    /// The full renderer and certified retirement share the same derived admission write.
    /// Status never mutates the Card, enrollment, Note definition or append-only history.
    func setStatus(_ status: String, cardID: String, workspace: String) throws {
        try core.execute(sql: """
            INSERT INTO notebook_review_material_state(workspace_id,card_id,status) VALUES(?,?,?)
            ON CONFLICT(workspace_id,card_id) DO UPDATE SET status=excluded.status
            """, values: [.text(workspace), .text(cardID), .text(status)])
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
