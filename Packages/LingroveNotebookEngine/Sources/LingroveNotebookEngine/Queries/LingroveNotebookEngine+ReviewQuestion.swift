import Foundation
import LingroveNotebook

/// A practice surface owns one immutable question, including its exact source/definition
/// fence and local images. It is neither an enrollment command nor a complete review snapshot.
/// Hosts compare both clocks after asynchronous reads and carry questionVersion when rating.
public nonisolated struct NotebookReviewQuestion: Sendable {
    public let cardID: String
    public let fence: NotebookBrowseFence
    public let review: NotebookChangeToken
    public let source: LingroveNotebookCardSource
    public let expression: String
    public let meaning: String
    public let model: NotebookReviewNoteCard
    public let rendered: ReviewRenderedCard
    public let images: [String: Data]
    public var questionVersion: String { get throws { try model.questionVersion(in: fence.version) } }
}

extension LingroveNotebookEngine {
    /// nil identifies an ordinary manual Card. A malformed/retired Note fails explicitly;
    /// falling back to its cached plain Card face would weaken the question-version fence.
    public func notebookReviewQuestion(cardID: String, workspaceID: String) throws -> NotebookReviewQuestion? {
        try core.inReadTransaction {
            try Task.checkCancellation()
            if try currentNotebookVersionInTransaction() == nil {
                guard try workspaceSettingsStore.loadCloudSettings().activeWorkspaceId == workspaceID else { throw VocabularyError.editConflict }
                guard try core.scalarInt(sql: "SELECT count(*) FROM notebook_note_cards WHERE workspace_id=? AND card_id=?",
                    values: [.text(workspaceID), .text(cardID)]) == 0 else { throw VocabularyError.invalidArchive }
                return nil
            }
            let fence = try browseFenceInTransaction()
            guard fence.version.workspaceId == workspaceID else { throw VocabularyError.editConflict }
            let store = ReviewNoteStore(core: core)
            guard let model = try store.cardModels(version: fence.version, cardIDs: [cardID])[cardID] else { return nil }
            guard let (entry, sense) = try store.source(for: model.note, workspace: workspaceID) else {
                throw ReviewTemplateError.sourceUnavailable
            }
            let rendered = try model.render(entry: entry, sense: sense)
            var images: [String: Data] = [:]
            for reference in VocabularyContentPolicy.images(sense.content ?? [])
                where rendered.frontHTML.contains(reference.filename) || rendered.backHTML.contains(reference.filename) {
                try Task.checkCancellation()
                images[reference.filename] = try LingroveNotebookMediaStore(core: core).ownedImage(reference, workspaceId: workspaceID)
            }
            return try .init(cardID: cardID, fence: fence, review: core.notebookChangeStamp().review,
                source: .init(workspaceId: workspaceID, notebookId: fence.version.notebookId,
                    entryId: entry.id, senseId: sense.id, exampleId: model.note.exampleID),
                expression: entry.expression, meaning: sense.meaning, model: model, rendered: rendered, images: images)
        }
    }
}
