import Foundation
import LingroveNotebook

/// Borrows the ownership transaction after its normal Card identity fork. This
/// copies existing participation; it never selects a previously unselected
/// sense. Historical journals and frozen requests remain in the source scope.
public nonisolated struct LingroveNotebookAccountReviewHandoff {
    public let core: DatabaseCore
    public func copyInTransaction(source: String, target: String, notebookID: UUID, cardIDs: [String: String], assetIDs: [String: String] = [:]) throws {
        let enrollments = try core.query(sql: "SELECT enrollment_id,sense_id FROM notebook_review_enrollments WHERE workspace_id=?", values: [.text(source)]) {
            (DatabaseCore.columnText(statement: $0, index: 0), DatabaseCore.columnText(statement: $0, index: 1))
        }
        var enrollmentIDs: [String: String] = [:]
        for (original, sense) in enrollments {
            if let existing = try core.query(sql: "SELECT enrollment_id FROM notebook_review_enrollments WHERE workspace_id=? AND notebook_id=? AND sense_id=?",
                values: [.text(target), .text(notebookID.uuidString), .text(sense)], map: { DatabaseCore.columnText(statement: $0, index: 0) }).first {
                // Preserve the account's current pause/withdrawal choice. Its
                // existing enrollment adopts copied exercises/history without
                // re-enrolling the sense or resetting either schedule.
                enrollmentIDs[original] = existing
            } else {
                guard let senseID = UUID(uuidString: sense) else { throw LingroveNotebookAccountError.unavailableSource }
                let replacement = LingroveNotebookCardMaterial.stableID("enrollment", workspace: target, sense: senseID).uuidString
                enrollmentIDs[original] = replacement
                try core.execute(sql: """
                    INSERT INTO notebook_review_enrollments(workspace_id,enrollment_id,notebook_id,entry_id,sense_id,status,revision,created_at,updated_at)
                    SELECT ?,?,?,entry_id,sense_id,status,revision,created_at,updated_at FROM notebook_review_enrollments WHERE workspace_id=? AND enrollment_id=?
                    """, values: [.text(target), .text(replacement), .text(notebookID.uuidString), .text(source), .text(original)])
            }
        }
        for (old, new) in cardIDs {
            let links = try core.query(sql: "SELECT link_id FROM notebook_card_links WHERE workspace_id=? AND card_id=?", values: [.text(source), .text(old)]) {
                DatabaseCore.columnText(statement: $0, index: 0)
            }
            for link in links {
                let replacement = forkedNotebookLinkID(source: source, target: target, original: link)
                try core.execute(sql: """
                INSERT INTO notebook_card_links(workspace_id,link_id,notebook_id,entry_id,sense_id,example_id,card_id,generated_content_json,source_revision,creation_fingerprint,revision,created_at,updated_at,deleted_at,allows_unavailable_material,material_plan_json)
                SELECT ?,?,?,entry_id,sense_id,example_id,?,generated_content_json,source_revision,creation_fingerprint,revision,created_at,updated_at,deleted_at,allows_unavailable_material,material_plan_json
                FROM notebook_card_links WHERE workspace_id=? AND link_id=?
                """, values: [.text(target), .text(replacement), .text(notebookID.uuidString), .text(new), .text(source), .text(link)])
                if let value = try LingroveNotebookCardLinkStore(core: core).find(workspaceId: target, id: UUID(uuidString: replacement)!), let generated = value.generatedContent {
                    let rewritten = CardEditorInput(frontText: markdownByRewritingManagedMediaAssetIds(text: generated.frontText, mediaAssetIdsBySourceId: assetIDs),
                        backText: markdownByRewritingManagedMediaAssetIds(text: generated.backText, mediaAssetIdsBySourceId: assetIDs), tags: generated.tags)
                    try core.execute(sql: "UPDATE notebook_card_links SET generated_content_json=? WHERE workspace_id=? AND link_id=?",
                        values: [.text(try core.encodeJsonString(value: rewritten)), .text(target), .text(replacement)])
                }
            }
            try core.execute(sql: """
                INSERT INTO notebook_card_sync_holds(workspace_id,card_id,notebook_id,creation_operation_id,created_at)
                SELECT ?,?,?,creation_operation_id,created_at FROM notebook_card_sync_holds WHERE workspace_id=? AND card_id=?
                """, values: [.text(target), .text(new), .text(notebookID.uuidString), .text(source), .text(old)])
            let exercises = try core.query(sql: "SELECT enrollment_id,link_id,created_at FROM notebook_review_exercises WHERE workspace_id=? AND card_id=?",
                values: [.text(source), .text(old)]) { (DatabaseCore.columnText(statement: $0, index: 0), DatabaseCore.columnText(statement: $0, index: 1), DatabaseCore.columnText(statement: $0, index: 2)) }
            for (enrollment, link, created) in exercises {
                guard let mapped = enrollmentIDs[enrollment] else { throw LingroveNotebookAccountError.unavailableSource }
                try core.execute(sql: "INSERT INTO notebook_review_exercises(workspace_id,enrollment_id,card_id,link_id,created_at) VALUES(?,?,?,?,?)",
                    values: [.text(target), .text(mapped), .text(new), .text(forkedNotebookLinkID(source: source, target: target, original: link)), .text(created)])
                guard let enrollment = try LingroveNotebookReviewStore(core: core).find(workspaceId: target, id: UUID(uuidString: mapped)!),
                      let originalBook = try core.query(sql: "SELECT notebook_id FROM notebook_state WHERE workspace_id=?", values: [.text(source)],
                        map: { UUID(uuidString: DatabaseCore.columnText(statement: $0, index: 0)) }).first ?? nil else { throw LingroveNotebookAccountError.unavailableSource }
                let eventIDs = try core.query(sql: "SELECT review_event_id FROM review_events WHERE workspace_id=? AND card_id=? ORDER BY review_event_id",
                    values: [.text(target), .text(new)], map: { DatabaseCore.columnText(statement: $0, index: 0) })
                guard eventIDs.count <= 100_000, let adoptedLink = UUID(uuidString: forkedNotebookLinkID(source: source, target: target, original: link)) else { throw VocabularyError.invalidContent }
                let adoption = LingroveNotebookReviewRequest.HistoryAdoption(operationId: UUID().uuidString.lowercased(),
                    enrollmentId: enrollment.id, cardId: new, linkId: adoptedLink, entryId: enrollment.entryId, senseId: enrollment.senseId,
                    originWorkspaceId: source, originNotebookId: originalBook, eventIds: eventIDs)
                try core.execute(sql: "INSERT INTO notebook_review_history_adoptions(workspace_id,operation_id,card_id,payload_json) VALUES(?,?,?,?)",
                    values: [.text(target), .text(adoption.operationId), .text(new), .text(try core.encodeJsonString(value: adoption))])
            }
        }
        // Ownership adoption is a fresh authorized publication of retained participation,
        // never an implicit enrollment. Journal the target graph only after every mapping
        // exists, so the held lane can publish it atomically on the next account sync.
        let reviews = LingroveNotebookReviewStore(core: core)
        let linkStore = LingroveNotebookCardLinkStore(core: core)
        for id in Set(enrollmentIDs.values) {
            guard let value = try reviews.find(workspaceId: target, id: UUID(uuidString: id)!) else { throw LingroveNotebookAccountError.unavailableSource }
            try reviews.record(value, baseRevision: 0)
        }
        for link in try linkStore.load(workspaceId: target, includingDeleted: true) where cardIDs.values.contains(link.cardId) {
            try linkStore.record(link: link, baseRevision: 0, cardOperationId: nil)
        }
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
