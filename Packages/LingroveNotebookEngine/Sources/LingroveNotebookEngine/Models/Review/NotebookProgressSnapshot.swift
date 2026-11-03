import Foundation

/// One read's durable notebook owner. A workspace can exist before its first notebook is
/// opened; representing that absence lets Progress show an empty state without creating data.
/// Generation changes on account ABA even when the workspace and document revision return.
public nonisolated struct NotebookProgressScope: Equatable, Sendable {
    public let workspaceID: String
    public let notebookID: UUID?
    public let revision: UInt64?
    public let generation: String

    public init(workspaceID: String, notebookID: UUID?, revision: UInt64?, generation: String) {
        self.workspaceID = workspaceID
        self.notebookID = notebookID
        self.revision = revision
        self.generation = generation
    }
}

/// A content-free publication fence, compared only on the connection that captured it.
/// Notebook revisions do not advance on every rating/undo; SQLite's external and local change
/// counters also invalidate a read when another writer commits without changing the document.
public nonisolated struct NotebookProgressReadFence: Equatable, Sendable {
    public let scope: NotebookProgressScope
    public let externalVersion: Int
    public let connectionChanges: Int64

    public init(scope: NotebookProgressScope, externalVersion: Int, connectionChanges: Int64) {
        self.scope = scope
        self.externalVersion = externalVersion
        self.connectionChanges = connectionChanges
    }
}

/// The portable engine returns one immutable, local-only statistical snapshot. Complete
/// effective history drives totals and streaks; the upstream 140-day window bounds only the
/// displayed chart. The app owns this value until its scope/change fence becomes stale.
public nonisolated struct NotebookProgressSnapshot: Sendable {
    public let scope: NotebookProgressScope
    public let now: Date
    public let calendar: Calendar
    public let range: ProgressRequestRange
    public let summary: ProgressSummary
    public let dailyReviews: [ProgressDay]
    public let streakDays: [ProgressStreakDay]
    public let schedule: UserReviewSchedule
    public let totalReviews: Int
    public let undoneReviews: Int
    public let enrolledSenses: Int
    public let activeSenses: Int
    public let exercises: Int

    public var hasHistory: Bool { totalReviews > 0 }
}

/// SQL has already restricted these events to owned corpus exercises and excluded undo rows.
/// Keeping the aggregation input independent of Card permits history to survive Card deletion.
nonisolated struct NotebookProgressEvent: Sendable {
    let id: String
    let reviewedAt: String
    let timeZone: String?
    let rating: ReviewRating
}

/// Only currently admitted, live exercises enter the forecast. A missing due date means new;
/// timestamp/millisecond consistency is checked at the storage boundary before aggregation.
nonisolated struct NotebookProgressDueExercise: Sendable {
    let dueMillis: Int64?
}
