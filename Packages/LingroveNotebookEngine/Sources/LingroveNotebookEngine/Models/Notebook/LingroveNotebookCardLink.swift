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

/// One editor session owns one creation intent. Reusing this ID after an uncertain save result
/// finds the same linked Card; opening another draft intentionally allows another exercise.
/// Generated content is frozen separately from the editable native CardFormState.
public nonisolated struct LingroveNotebookCardDraft: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let source: LingroveNotebookCardSource
    public let sourceRevision: UInt64
    public let generatedContent: CardEditorInput

    public init(id: UUID, source: LingroveNotebookCardSource, sourceRevision: UInt64, generatedContent: CardEditorInput) {
        self.id = id
        self.source = source
        self.sourceRevision = sourceRevision
        self.generatedContent = generatedContent
    }
}

/// A durable relationship contains no Card scheduling fields and no Anki identities. A nil
/// generatedContent means an existing Card was associated: its faces are manually owned until
/// the person explicitly chooses to replace them. Deleting a link leaves a tombstone, not a
/// Card deletion. Revision is local CAS state, independent of the notebook document revision.
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
    public var allowsUnavailableMaterial: Bool = false

    public init(id: UUID, source: LingroveNotebookCardSource, cardId: String, generatedContent: CardEditorInput?, sourceRevision: UInt64, creationFingerprint: String, revision: UInt64, createdAt: String, updatedAt: String, deletedAt: String?, allowsUnavailableMaterial: Bool = false) {
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
        self.allowsUnavailableMaterial = allowsUnavailableMaterial
    }
}

/// Presentation resolves a historical sense to today's destination. The optional example is
/// material owned by that sense, never the identity of the exercise. Moving it to another sense
/// leaves the original material unavailable rather than moving the person's review history.
public nonisolated struct LingroveNotebookCardMaterial: Sendable {
    public let selection: VocabularySelection
    public let exampleId: UUID?
    public let content: CardEditorInput

    public init(selection: VocabularySelection, exampleId: UUID?, content: CardEditorInput) {
        self.selection = selection
        self.exampleId = exampleId
        self.content = content
    }
}
