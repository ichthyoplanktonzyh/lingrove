import Foundation
import LingroveNotebook

/// The corpus detail needs three participation values, not a review queue or a full notebook.
/// This immutable result crosses the native IO actor; it never owns a repository or a writer.
public nonisolated struct LingroveNotebookParticipation: Equatable, Sendable {
    public let status: LingroveNotebookReviewStatus?
    public let exerciseCount: Int
    public let hasUnavailableMaterial: Bool
}

extension LingroveNotebookEngine {
    /// Reads the selected sense and its historical aliases in one transaction. The metadata
    /// fence prevents an account switch or corpus edit from attaching another scope's status.
    /// No full-document decode/validation belongs on this frequently repeated browsing path.
    public func loadNotebookParticipation(selection: VocabularySelection,
                                          version: LingroveNotebookVersion) throws -> LingroveNotebookParticipation {
        try core.inReadTransaction {
            try Task.checkCancellation()
            try lingroveNotebookCardLinkStore.requireActiveScope(workspaceId: version.workspaceId, notebookId: version.notebookId)
            guard try LingroveNotebookLocalScopeStore(core: core).generationInTransaction() == version.generation,
                  try core.scalarInt(sql: "SELECT revision FROM notebook_state WHERE workspace_id=?",
                    values: [.text(version.workspaceId)]) == Int(version.revision) else { throw VocabularyError.editConflict }
            let senses = try core.query(sql: "SELECT payload_json FROM notebook_senses WHERE workspace_id=? AND parent_id=? AND id=?",
                values: [.text(version.workspaceId), .text(selection.entryID.uuidString), .text(selection.senseID.uuidString)]) {
                try JSONDecoder().decode(VocabularySense.self, from: Data(DatabaseCore.columnText(statement: $0, index: 0).utf8))
            }
            guard let sense = senses.first, sense.id == selection.senseID else { throw VocabularyError.editConflict }
            let aliases = Set([sense.id] + sense.mergedFrom)
            let enrollments = try lingroveNotebookReviewStore.load(workspaceId: version.workspaceId,
                notebookId: version.notebookId, senseIDs: aliases)
            var count = 0, unavailable = false
            for enrollment in enrollments {
                for exercise in try lingroveNotebookReviewStore.exercises(enrollment) {
                    try Task.checkCancellation()
                    guard let card = try cardStore.loadOptionalCardIncludingDeleted(workspaceId: version.workspaceId,
                        cardId: exercise.cardId), card.deletedAt == nil else { continue }
                    _ = try requireValidBuiltInReviewCard(card)
                    count += 1
                    if try ReviewNoteStore(core: core).isTemplateDisabled(cardID: card.cardId, workspace: version.workspaceId) {
                        continue
                    }
                    if try core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_review_material_state WHERE workspace_id=? AND card_id=? AND status NOT IN ('ready','retained')",
                        values: [.text(version.workspaceId), .text(card.cardId)]) > 0 { unavailable = true }
                }
            }
            let status: LingroveNotebookReviewStatus? = enrollments.isEmpty ? nil :
                enrollments.contains(where: { $0.status == .active }) ? .active :
                enrollments.contains(where: { $0.status == .paused }) ? .paused : .withdrawn
            return .init(status: status, exerciseCount: count, hasUnavailableMaterial: unavailable)
        }
    }
}

extension ReviewNoteStore {
    /// Resolve only the selected Card's Note. Loading every Note to find one disabled template
    /// would make corpus browsing grow with the size of the separate review collection too.
    fileprivate func isTemplateDisabled(cardID: String, workspace: String) throws -> Bool {
        let matches = try core.query(sql: """
            SELECT note.payload_json,member.template_id FROM notebook_note_cards member
            JOIN notebook_notes note ON note.workspace_id=member.workspace_id AND note.note_id=member.note_id
            WHERE member.workspace_id=? AND member.card_id=?
            """, values: [.text(workspace), .text(cardID)]) { statement in
                (try core.decoder.decode(ReviewNote.self, from: Data(DatabaseCore.columnText(statement: statement, index: 0).utf8)),
                 UUID(uuidString: DatabaseCore.columnText(statement: statement, index: 1)))
            }
        guard let (note, templateID) = matches.first else { return false }
        guard let templateID, let type = try types(workspace: workspace).first(where: { $0.id == note.noteTypeID }) else {
            throw VocabularyError.invalidArchive
        }
        return type.templates.first(where: { $0.id == templateID })?.enabled == false
    }
}
