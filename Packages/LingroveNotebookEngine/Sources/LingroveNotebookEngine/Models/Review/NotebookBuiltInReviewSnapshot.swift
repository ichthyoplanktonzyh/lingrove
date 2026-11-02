import Foundation
import LingroveNotebook

/// A native notebook review screen borrows this immutable read. It contains no connection,
/// credential or second progress store: Cards remain the scheduler truth, and events are history.
/// The owning session retains `scope` with every button or editor opened from this value.
public struct NotebookBuiltInReviewSnapshot: Sendable {
    public let scope: LingroveNotebookSnapshot
    public let review: LingroveNotebookReviewSnapshot
    public let schedulerSettings: WorkspaceSchedulerSettings
    public let queue: [Card]
    public let eligibleCardIDs: Set<String>
    public let statistics: NotebookBuiltInReviewStatistics
    public let undoByCardID: [String: NotebookBuiltInReviewUndo]
    public let recentHistory: [NotebookBuiltInReviewHistory]

    public init(scope: LingroveNotebookSnapshot, review: LingroveNotebookReviewSnapshot,
                schedulerSettings: WorkspaceSchedulerSettings, queue: [Card], eligibleCardIDs: Set<String>,
                statistics: NotebookBuiltInReviewStatistics, undoByCardID: [String: NotebookBuiltInReviewUndo],
                recentHistory: [NotebookBuiltInReviewHistory]) {
        self.scope = scope
        self.review = review
        self.schedulerSettings = schedulerSettings
        self.queue = queue
        self.eligibleCardIDs = eligibleCardIDs
        self.statistics = statistics
        self.undoByCardID = undoByCardID
        self.recentHistory = recentHistory
    }
}

/// Sense counts describe participation; exercise counts describe independent Card memories.
/// Keeping both prevents an additional exercise or a merged source from inflating vocabulary.
public struct NotebookBuiltInReviewStatistics: Equatable, Sendable {
    public let activeSenses: Int
    public let pausedSenses: Int
    public let withdrawnSenses: Int
    public let exercises: Int
    public let readyExercises: Int
    public let newExercises: Int
    public let reviewedExercises: Int
    public let ratingRecords: Int
    public let undoneRatings: Int

    public init(activeSenses: Int, pausedSenses: Int, withdrawnSenses: Int, exercises: Int,
                readyExercises: Int, newExercises: Int, reviewedExercises: Int, ratingRecords: Int, undoneRatings: Int) {
        self.activeSenses = activeSenses
        self.pausedSenses = pausedSenses
        self.withdrawnSenses = withdrawnSenses
        self.exercises = exercises
        self.readyExercises = readyExercises
        self.newExercises = newExercises
        self.reviewedExercises = reviewedExercises
        self.ratingRecords = ratingRecords
        self.undoneRatings = undoneRatings
    }
}

/// An undo button names the rating it displayed, in addition to the caller's saved generation.
/// Reading a newer last-rating row when an old button fires must not undo another device's work.
public struct NotebookBuiltInReviewUndo: Equatable, Sendable {
    public let cardID: String
    public let cardOperationID: String
    public let ratingOperationID: String

    public init(cardID: String, cardOperationID: String, ratingOperationID: String) {
        self.cardID = cardID
        self.cardOperationID = cardOperationID
        self.ratingOperationID = ratingOperationID
    }
}

/// History is deliberately presentation-only. An undone rating remains visible and contributes
/// to the record count; neither this list nor its order reconstructs a Card's FSRS state.
public struct NotebookBuiltInReviewHistory: Identifiable, Sendable {
    public let id: String
    public let cardID: String
    public let rating: ReviewRating
    public let reviewedAt: String
    public let wasUndone: Bool

    public init(id: String, cardID: String, rating: ReviewRating, reviewedAt: String, wasUndone: Bool) {
        self.id = id
        self.cardID = cardID
        self.rating = rating
        self.reviewedAt = reviewedAt
        self.wasUndone = wasUndone
    }
}

/// A native action retains the entire sense group it displayed, not just the latest notebook
/// revision. Ratings and participation changes can occur without a corpus edit; their original
/// Card/link/enrollment identities therefore travel with the saved scope to the writer lock.
public struct NotebookBuiltInReviewAction: Sendable {
    public let scope: LingroveNotebookSnapshot
    public let selection: VocabularySelection
    public let enrollments: [LingroveNotebookReviewEnrollment]
    public let cards: [Card]
    public let links: [LingroveNotebookCardLink]
    public let schedulerSettings: WorkspaceSchedulerSettings

    public init(content: NotebookBuiltInReviewSnapshot, selection: VocabularySelection) {
        scope = content.scope
        self.selection = selection
        let group = content.review.groups[selection.senseID]
        enrollments = group?.enrollments ?? []
        cards = group?.cards ?? []
        let ids = Set(cards.map(\.cardId))
        links = content.review.links.filter { ids.contains($0.cardId) }
        schedulerSettings = content.schedulerSettings
    }
}
