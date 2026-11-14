import Foundation
import LingroveNotebook

/// One form owns a frozen Note/type and its canonical source subtree. This is an editing
/// read, not a partial corpus snapshot. Only the shared writer may admit its saved fence.
public nonisolated struct NotebookNoteEditingMaterial: Sendable {
    public let fence: NotebookBrowseFence
    public let review: NotebookChangeToken
    public let model: NotebookReviewNoteCard
    public let entry: VocabularyEntry
    public let sense: VocabularySense
}

public nonisolated struct NotebookNotePreview: Sendable {
    public let rendered: ReviewRenderedCard
    public let images: [String: Data]
}

extension LingroveNotebookEngine {
    public func notebookNoteEditor(cardID: String, workspaceID: String) throws -> NotebookNoteEditingMaterial {
        try core.inReadTransaction {
            try Task.checkCancellation()
            let fence = try browseFenceInTransaction()
            guard fence.version.workspaceId == workspaceID else { throw VocabularyError.editConflict }
            let store = ReviewNoteStore(core: core)
            guard let model = try store.cardModels(version: fence.version, cardIDs: [cardID])[cardID],
                  let (entry, sense) = try store.source(for: model.note, workspace: workspaceID) else {
                throw ReviewTemplateError.sourceUnavailable
            }
            return try .init(fence: fence, review: core.notebookChangeStamp().review, model: model, entry: entry, sense: sense)
        }
    }

    /// Preview borrows canonical source/images under the exact source fence. Proposed types
    /// are ephemeral; disabled/new templates can be previewed without enrolling any Cards.
    public func previewNotebookNote(_ proposed: NotebookReviewNoteCard, basedOn material: NotebookNoteEditingMaterial) throws -> NotebookNotePreview {
        try core.inReadTransaction {
            try requireNoteEditVersion(material.fence.version, corpus: material.fence.corpus)
            try Task.checkCancellation()
            let store = ReviewNoteStore(core: core)
            guard try store.note(id: material.model.note.id, version: material.fence.version) == material.model.note,
                  try store.type(id: material.model.noteType.id, workspace: material.fence.version.workspaceId) == material.model.noteType,
                  proposed.note.id == material.model.note.id, proposed.note.entryID == material.model.note.entryID,
                  proposed.note.senseID == material.model.note.senseID, proposed.note.noteTypeID == proposed.noteType.id,
                  let template = proposed.noteType.templates.first(where: { $0.id == proposed.templateID }) else {
                throw VocabularyError.editConflict
            }
            var resolved = proposed.note; resolved.entryID = material.entry.id
            let fields = try ReviewNoteProjection.fields(note: resolved, type: proposed.noteType,
                entry: material.entry, sense: material.sense)
            let rendered = try ReviewTemplateRenderer.render(type: proposed.noteType, template: template, fields: fields)
            var images: [String: Data] = [:]
            for reference in VocabularyContentPolicy.images(material.sense.content ?? [])
                where rendered.frontHTML.contains(reference.filename) || rendered.backHTML.contains(reference.filename) {
                try Task.checkCancellation()
                images[reference.filename] = try LingroveNotebookMediaStore(core: core).ownedImage(reference,
                    workspaceId: material.fence.version.workspaceId)
            }
            return .init(rendered: rendered, images: images)
        }
    }

    func requireNoteEditVersion(_ version: LingroveNotebookVersion, corpus: NotebookChangeToken?) throws {
        guard try currentNotebookVersionInTransaction() == version else { throw VocabularyError.editConflict }
        if let corpus, try core.notebookChangeStamp().corpus != corpus { throw VocabularyError.editConflict }
    }
}
