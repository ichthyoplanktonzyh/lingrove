import Foundation
import LingroveNotebook
import LingroveNotebookSync

/// Typed held-lane envelope. It reuses native Card and ReviewEvent contracts while keeping
/// participation, provenance, faces, scheduling and event acknowledgments independent.
public nonisolated struct LingroveNotebookReviewRequest: Codable, Sendable {
    /// Only account acceptance creates this immutable, finite history manifest.
    /// Origin IDs grant no authority to read another workspace or revive corpus.
    public struct HistoryAdoption: Codable, Sendable {
        public let operationId: String
        public let enrollmentId: UUID
        public let cardId: String
        public let linkId: UUID
        public let entryId: UUID
        public let senseId: UUID
        public let originWorkspaceId: String
        public let originNotebookId: UUID
        public let eventIds: [String]

        public init(operationId: String, enrollmentId: UUID, cardId: String, linkId: UUID, entryId: UUID, senseId: UUID, originWorkspaceId: String, originNotebookId: UUID, eventIds: [String]) {
            self.operationId = operationId
            self.enrollmentId = enrollmentId
            self.cardId = cardId
            self.linkId = linkId
            self.entryId = entryId
            self.senseId = senseId
            self.originWorkspaceId = originWorkspaceId
            self.originNotebookId = originNotebookId
            self.eventIds = eventIds
        }
}
    public struct Enrollment: Codable, Sendable {
    public let operationId: String
    public let value: LingroveNotebookReviewEnrollment

        public init(operationId: String, value: LingroveNotebookReviewEnrollment) {
            self.operationId = operationId
            self.value = value
        }
}
    public struct Link: Codable, Sendable {
    public let operationId: String
    public let enrollmentId: UUID
    public let value: LingroveNotebookCardLink

        public init(operationId: String, enrollmentId: UUID, value: LingroveNotebookCardLink) {
            self.operationId = operationId
            self.enrollmentId = enrollmentId
            self.value = value
        }
}
    public struct Confirmation: Codable, Sendable {
    public let cardId: String
    public let linkRevision: UInt64
    public let cardOperationId: String

        public init(cardId: String, linkRevision: UInt64, cardOperationId: String) {
            self.cardId = cardId
            self.linkRevision = linkRevision
            self.cardOperationId = cardOperationId
        }
}
    public struct Operation: Codable, Sendable {
    public let operation: VocabularyWireJSON
    public let initial: Bool
    public let schedule: Bool

        public init(operation: VocabularyWireJSON, initial: Bool, schedule: Bool) {
            self.operation = operation
            self.initial = initial
            self.schedule = schedule
        }
}
    public let protocolVersion: Int
    public let notebookId: UUID
    public let replicaId: UUID
    public let installationId: UUID
    public let afterSequence: Int64
    public let sourceSequence: String
    public let enrollments: [Enrollment]
    public let links: [Link]
    public let operations: [Operation]
    public let undos: [LingroveNotebookReviewUndo]
    public let confirmations: [Confirmation]
    public let historyAdoptions: [HistoryAdoption]
    public let noteBase: ReviewNoteSyncState?
    public let noteStateDigest: String?
    public let noteState: ReviewNoteSyncState?
    public let media: [ReviewMaterialPreparedMedia]?
    public init(protocolVersion: Int, notebookId: UUID, replicaId: UUID, installationId: UUID, afterSequence: Int64, sourceSequence: String,
         enrollments: [Enrollment], links: [Link], operations: [Operation], undos: [LingroveNotebookReviewUndo],
         confirmations: [Confirmation], historyAdoptions: [HistoryAdoption] = [], media: [ReviewMaterialPreparedMedia]? = nil, noteState: ReviewNoteSyncState? = nil, noteBase: ReviewNoteSyncState? = nil) {
        self.protocolVersion = protocolVersion; self.notebookId = notebookId; self.replicaId = replicaId; self.installationId = installationId
        self.afterSequence = afterSequence; self.sourceSequence = sourceSequence; self.enrollments = enrollments; self.links = links
        self.operations = operations; self.undos = undos; self.confirmations = confirmations; self.historyAdoptions = historyAdoptions; self.media = media; self.noteState = noteState; self.noteBase = noteBase; self.noteStateDigest = try? noteState?.digest()
    }
}

public nonisolated struct LingroveNotebookReviewUndo: Codable, Sendable {
    public let undoId: String
    public let cardId: String
    public let eventId: String
    public let targetOperationId: String
    public let previousCard: Card
    public let createdAt: String

    public init(undoId: String, cardId: String, eventId: String, targetOperationId: String, previousCard: Card, createdAt: String) {
        self.undoId = undoId
        self.cardId = cardId
        self.eventId = eventId
        self.targetOperationId = targetOperationId
        self.previousCard = previousCard
        self.createdAt = createdAt
    }
}

public nonisolated struct LingroveNotebookReviewResponse: Decodable, Sendable {
    public struct Change: Decodable, Sendable {
    public let sequence: String
    public let kind: String
    public let value: VocabularyWireJSON

        public init(sequence: String, kind: String, value: VocabularyWireJSON) {
            self.sequence = sequence
            self.kind = kind
            self.value = value
        }
}
    public let protocolVersion: Int
    public let notebookId: UUID
    public let replicaId: UUID
    public let acknowledged: [String]
    public let confirmed: [String]
    public let afterSequence: Int64
    public let hasMore: Bool
    public let changes: [Change]
    public let noteState: ReviewNoteSyncState?
    public let media: [ReviewMaterialPreparedMedia]?
    public let acknowledgedNoteState: String?
    public let acknowledgedMedia: [String]?

    public init(protocolVersion: Int, notebookId: UUID, replicaId: UUID, acknowledged: [String], confirmed: [String], afterSequence: Int64, hasMore: Bool, changes: [Change], media: [ReviewMaterialPreparedMedia]? = nil, acknowledgedMedia: [String]? = nil, noteState: ReviewNoteSyncState? = nil, acknowledgedNoteState: String? = nil) {
        self.protocolVersion = protocolVersion
        self.notebookId = notebookId
        self.replicaId = replicaId
        self.acknowledged = acknowledged
        self.confirmed = confirmed
        self.afterSequence = afterSequence
        self.hasMore = hasMore
        self.changes = changes
        self.media = media; self.acknowledgedMedia = acknowledgedMedia
        self.noteState = noteState; self.acknowledgedNoteState = acknowledgedNoteState
    }
}
