import Foundation
import LingroveNotebook

/// A pinned note/template pair is part of the displayed question's fence. Template edits are
/// review changes even when their plain text is unchanged; rating must compare these values.
public struct NotebookReviewNoteCard: Codable, Equatable, Sendable {
    public let note: ReviewNote
    public let noteType: ReviewNoteType
    public let templateID: UUID
    public init(note: ReviewNote, noteType: ReviewNoteType, templateID: UUID) {
        self.note = note; self.noteType = noteType; self.templateID = templateID
    }
    /// This token names the exact question content/definition and source revision. It is carried
    /// through mobile's asynchronous submission queue, where a Card text-only fence is weaker.
    public func questionVersion(in scope: LingroveNotebookSnapshot) throws -> String {
        struct Value: Encodable {
            let model: NotebookReviewNoteCard
            let workspace: String
            let notebook: UUID
            let revision: UInt64
            let generation: String
        }
        return try LingroveNotebookCardMaterial.fingerprint(Value(model: self, workspace: scope.workspaceId,
            notebook: scope.notebookId, revision: scope.revision, generation: scope.generation))
    }
    public func render(in snapshot: LingroveNotebookSnapshot) throws -> ReviewRenderedCard {
        guard let template = noteType.templates.first(where: { $0.id == templateID && $0.enabled }),
              let entry = snapshot.document.entries.first(where: { $0.senses.contains { $0.id == note.senseID || $0.mergedFrom.contains(note.senseID) } }),
              let sense = entry.senses.first(where: { $0.id == note.senseID || $0.mergedFrom.contains(note.senseID) }) else {
            throw ReviewTemplateError.sourceUnavailable
        }
        var resolved = note; resolved.entryID = entry.id
        let fields = try ReviewNoteProjection.fields(note: resolved, type: noteType, entry: entry, sense: sense)
        return try ReviewTemplateRenderer.render(type: noteType, template: template, fields: fields)
    }
}
