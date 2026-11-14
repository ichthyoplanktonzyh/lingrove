import Foundation
import LingroveNotebook

/// A review link keeps its original notebook provenance even after a sense merge or usage move.
/// The link store owns these values; Cards keep their own content, scheduler and review events.
/// Source IDs are historical references, resolved against the current notebook rather than tied
/// to a cascading foreign key that could delete an exercise when notebook material is retired.
public nonisolated struct LingroveNotebookCardSource: Codable, Hashable, Sendable {
    public let workspaceId: String
    public let notebookId: UUID
    public let entryId: UUID
    public let senseId: UUID
    public let exampleId: UUID?

    public init(workspaceId: String, notebookId: UUID, entryId: UUID, senseId: UUID, exampleId: UUID?) {
        self.workspaceId = workspaceId
        self.notebookId = notebookId
        self.entryId = entryId
        self.senseId = senseId
        self.exampleId = exampleId
    }
}

/// Note reconciliation creates this value inside its transaction to persist provenance.
/// Stable Note/template membership owns creation identity; callers cannot author another recipe.
nonisolated struct ReviewNoteCardLinkDraft {
    let id: UUID
    let source: LingroveNotebookCardSource
    let sourceRevision: UInt64
    let generatedContent: CardEditorInput


}

/// A durable Note Card relationship contains provenance, its generated projection and local
/// CAS revision. Scheduling and review events remain owned by CardStore.
public nonisolated struct LingroveNotebookCardLink: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let source: LingroveNotebookCardSource
    public let cardId: String
    public let generatedContent: CardEditorInput?
    public let sourceRevision: UInt64
    public let creationFingerprint: String
    public let revision: UInt64
    public let createdAt: String
    public let updatedAt: String
    public let deletedAt: String?

    public init(id: UUID, source: LingroveNotebookCardSource, cardId: String, generatedContent: CardEditorInput?,
                sourceRevision: UInt64, creationFingerprint: String, revision: UInt64, createdAt: String,
                updatedAt: String, deletedAt: String?) {
        self.id = id
        self.source = source
        self.cardId = cardId
        self.generatedContent = generatedContent
        self.sourceRevision = sourceRevision
        self.creationFingerprint = creationFingerprint
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Pure identities and source resolution shared by Note persistence and source navigation.
/// It has no card-authoring state: Note fields and templates own every generated face.
public nonisolated enum LingroveNotebookCardMaterial {}
