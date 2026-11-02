import Foundation
import LingroveNotebook

/// Notebook writers invoke this adapter inside their existing transaction, after replacing
/// source rows. It projects only faces/tags; the Card's FSRS fields and append-only events are
/// never touched. Missing evidence is persisted as queue admission state, not guessed at read.
public struct LingroveNotebookReviewMaterialStore {
    public let core: DatabaseCore

    public func refreshInTransaction(_ snapshot: LingroveNotebookSnapshot) throws {
        let links = LingroveNotebookCardLinkStore(core: core)
        let cards = CardStore(core: core)
        let settings = try WorkspaceSettingsStore(core: core).loadCloudSettings()
        for link in try links.load(workspaceId: snapshot.workspaceId) {
            guard let card = try cards.loadOptionalCardIncludingDeleted(workspaceId: snapshot.workspaceId, cardId: link.cardId), card.deletedAt == nil else { continue }
            let material = LingroveNotebookCardMaterial.resolve(source: link.source, snapshot: snapshot)
            let state = material == nil && link.allowsUnavailableMaterial ? "retained" : material == nil ? (LingroveNotebookCardMaterial.resolvedSelection(source: link.source, snapshot: snapshot) == nil ? "sourceMissing" : "exampleMissing") : "ready"
            try core.execute(sql: "INSERT INTO notebook_review_material_state(workspace_id,card_id,status) VALUES(?,?,?) ON CONFLICT(workspace_id,card_id) DO UPDATE SET status=excluded.status",
                values: [.text(snapshot.workspaceId), .text(card.cardId), .text(state)])
            guard let material else { continue }
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
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
