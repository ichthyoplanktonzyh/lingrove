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
        try questionVersion(in: LingroveNotebookVersion(scope))
    }

    func questionVersion(in scope: LingroveNotebookVersion) throws -> String {
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
        let (entry, sense) = try Self.source(for: note, in: snapshot)
        return try render(entry: entry, sense: sense)
    }

    static func source(for note: ReviewNote, in snapshot: LingroveNotebookSnapshot) throws -> (VocabularyEntry, VocabularySense) {
        let source = LingroveNotebookCardSource(workspaceId: snapshot.workspaceId, notebookId: snapshot.notebookId,
            entryId: note.entryID, senseId: note.senseID, exampleId: note.exampleID)
        guard let selection = LingroveNotebookCardMaterial.resolvedSelection(source: source, snapshot: snapshot),
              let entry = VocabularyNotebookProjection.entry(selection.entryID, in: snapshot.document),
              let sense = entry.senses.first(where: { $0.id == selection.senseID }) else {
            throw ReviewTemplateError.sourceUnavailable
        }
        return (entry, sense)
    }

    func render(entry: VocabularyEntry, sense: VocabularySense,
                using prepared: ReviewTemplateRenderer.Prepared? = nil) throws -> ReviewRenderedCard {
        guard let template = noteType.templates.first(where: { $0.id == templateID && $0.enabled }) else {
            throw ReviewTemplateError.sourceUnavailable
        }
        let definition = try prepared ?? ReviewTemplateRenderer.Prepared(noteType)
        guard definition.type == noteType else { throw ReviewTemplateError.invalidDefinition }
        var resolved = note; resolved.entryID = entry.id
        let fields = try ReviewNoteProjection.fields(note: resolved, prepared: definition, entry: entry, sense: sense)
        return try definition.render(templateID: template.id, fields: fields)
    }
}
