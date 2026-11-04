import Foundation
import LingroveNotebook

/// A background read builds one immutable view of participation, exercises and provenance.
/// The library owns it only while its notebook scope/revision matches. Views never open SQLite
/// connections, and loading this value does not enroll any corpus material.
public nonisolated struct LingroveNotebookReviewSnapshot: Sendable {
    public let workspaceId: String
    public let notebookId: UUID
    public let notebookRevision: UInt64
    public let groups: [UUID: LingroveNotebookReviewGroup]
    public let links: [LingroveNotebookCardLink]
    public var hasPendingSync: Bool = false
    public let noteCards: [String: NotebookReviewNoteCard]

    public func matches(_ notebook: LingroveNotebookSnapshot) -> Bool {
        workspaceId == notebook.workspaceId && notebookId == notebook.notebookId && notebookRevision == notebook.revision
    }

    public init(workspaceId: String, notebookId: UUID, notebookRevision: UInt64, groups: [UUID: LingroveNotebookReviewGroup], links: [LingroveNotebookCardLink], hasPendingSync: Bool = false, noteCards: [String: NotebookReviewNoteCard] = [:]) {
        self.workspaceId = workspaceId
        self.notebookId = notebookId
        self.notebookRevision = notebookRevision
        self.groups = groups
        self.links = links
        self.hasPendingSync = hasPendingSync
        self.noteCards = noteCards
    }
}

/// One visible sense may retain several historical enrollments after a merge. Presentation
/// groups them once, while each original Card keeps its content, scheduling and event history.
public nonisolated struct LingroveNotebookReviewGroup: Sendable {
    public let selection: VocabularySelection
    public let enrollments: [LingroveNotebookReviewEnrollment]
    public let cards: [Card]
    public let hasUnavailableMaterial: Bool
    public let undoableCardIDs: Set<String>
    public init(selection: VocabularySelection, enrollments: [LingroveNotebookReviewEnrollment], cards: [Card],
        hasUnavailableMaterial: Bool = false, undoableCardIDs: Set<String> = []) {
        self.selection = selection; self.enrollments = enrollments; self.cards = cards
        self.hasUnavailableMaterial = hasUnavailableMaterial; self.undoableCardIDs = undoableCardIDs
    }

    public var status: LingroveNotebookReviewStatus {
        if enrollments.contains(where: { $0.status == .active }) { return .active }
        if enrollments.contains(where: { $0.status == .paused }) { return .paused }
        return .withdrawn
    }
}
