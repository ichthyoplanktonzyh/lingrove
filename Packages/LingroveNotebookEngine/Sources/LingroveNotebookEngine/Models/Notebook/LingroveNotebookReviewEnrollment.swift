import Foundation

/// Participation is independent of collection and of a Card's scheduler. The notebook library
/// presents these immutable values; the database owns their lifetime. Pausing or withdrawing
/// stops admission to the review queue without deleting exercises or resetting their history.
public nonisolated enum LingroveNotebookReviewStatus: String, Codable, Sendable {
    case active
    case paused
    case withdrawn
}

/// A durable enrollment names a sense, without an example ID. Historical sense IDs survive
/// merges; resolving them against the current notebook groups prior enrollments under the
/// surviving sense while retaining each exercise and its progress. Revision is local CAS state,
/// not the notebook document revision or a future server version.
public nonisolated struct LingroveNotebookReviewEnrollment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let workspaceId: String
    public let notebookId: UUID
    public let entryId: UUID
    public let senseId: UUID
    public let status: LingroveNotebookReviewStatus
    public let revision: UInt64
    public let createdAt: String
    public let updatedAt: String

    public var source: LingroveNotebookCardSource {
        .init(workspaceId: workspaceId, notebookId: notebookId, entryId: entryId, senseId: senseId, exampleId: nil)
    }

    public init(id: UUID, workspaceId: String, notebookId: UUID, entryId: UUID, senseId: UUID, status: LingroveNotebookReviewStatus, revision: UInt64, createdAt: String, updatedAt: String) {
        self.id = id
        self.workspaceId = workspaceId
        self.notebookId = notebookId
        self.entryId = entryId
        self.senseId = senseId
        self.status = status
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// The enrollment owns this mapping, while CardStore owns the referenced exercise and all
/// scheduler fields. Keeping the mapping explicit lets queue admission distinguish managed
/// corpus exercises from independent legacy Cards without interpreting display text or tags.
public nonisolated struct LingroveNotebookReviewExercise: Codable, Hashable, Sendable {
    public let enrollmentId: UUID
    public let cardId: String
    public let linkId: UUID
    public let createdAt: String

    public init(enrollmentId: UUID, cardId: String, linkId: UUID, createdAt: String) {
        self.enrollmentId = enrollmentId
        self.cardId = cardId
        self.linkId = linkId
        self.createdAt = createdAt
    }
}
