import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

/// Actual SQLite checks for the native notebook entrance. They exercise shared commands and
/// durable rows, including failed-action rollback, rather than a mock scheduler or UI counters.
@MainActor
struct BuiltInNotebookReviewIntegrationTests {
    private let now = Date(timeIntervalSince1970: 1_793_664_000)

    @Test("Corpus participation reads match review state without writing or decoding unrelated corpus rows")
    func boundedParticipationReadPreservesMergeAndRevisionFences() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        let empty = try engine.loadNotebookParticipation(selection: selection, version: .init(saved))
        #expect(empty.status == nil && empty.exerciseCount == 0)
        var content = try enroll(engine, saved: saved, selection: selection)
        let second = VocabularySelection(entryID: selection.entryID, senseID: saved.document.catalog[0].senses[1].id)
        content = try enroll(engine, saved: saved, selection: second)
        try engine.setBuiltInNotebookReviewStatus(.paused, action: .init(content: content, selection: selection), requestID: UUID())
        let before = try rowCounts(engine)
        let paused = try engine.loadNotebookParticipation(selection: selection, version: .init(saved))
        #expect(paused.status == .paused && paused.exerciseCount == 1 && !paused.hasUnavailableMaterial)
        #expect(try rowCounts(engine) == before)
        var document = saved.document
        var entries = document.entries
        try VocabularySenseEditingPolicy.merge(source: second.senseID, into: selection.senseID, in: &entries[0], now: now)
        document.entries = entries
        let merged = try engine.saveLingroveNotebook(document, basedOn: saved)
        let summary = try engine.loadNotebookParticipation(selection: selection, version: .init(merged))
        let full = try engine.loadBuiltInNotebookReview(scope: merged, now: now).review.groups[selection.senseID]
        #expect(summary.exerciseCount == 2 && summary.status == full?.status)
        #expect(summary.hasUnavailableMaterial == full?.hasUnavailableMaterial)
        #expect(throws: VocabularyError.editConflict) {
            try engine.loadNotebookParticipation(selection: selection, version: .init(saved))
        }
        #expect(throws: VocabularyError.editConflict) {
            try engine.loadNotebookParticipation(selection: second, version: .init(merged))
        }
        // A read of the selected sense does not visit the unrelated source-evidence table.
        // The full notebook validator still owns corruption detection on a corpus reload.
        try engine.core.execute(sql: "UPDATE notebook_sources SET payload_json='invalid' WHERE workspace_id=?",
            values: [.text(merged.workspaceId)])
        #expect(try engine.loadNotebookParticipation(selection: selection, version: .init(merged)) == summary)
        let wrong = LingroveNotebookVersion(workspaceId: merged.workspaceId, notebookId: merged.notebookId,
            revision: merged.revision, generation: "retired-generation")
        #expect(throws: VocabularyError.editConflict) {
            try engine.loadNotebookParticipation(selection: selection, version: wrong)
        }
    }



    @Test("Invalid persisted scheduling is rejected by notebook reads and ratings without repair or journal writes")
    func invalidScheduleFailsWithoutMutation() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        let content = try enroll(engine, saved: saved, selection: selection)
        let card = try #require(content.queue.first)
        let action = NotebookBuiltInReviewAction(content: content, selection: selection)
        // This models a corrupt local row while deliberately retaining its old operation ID.
        // The notebook boundary must inspect it before the legacy reader can reset a new Card.
        try engine.core.execute(sql: "UPDATE cards SET fsrs_stability=0.5 WHERE card_id=?", values: [.text(card.cardId)])
        let row = try exactRows(engine, table: "cards")
        let events = try exactRows(engine, table: "review_events")
        let journal = try exactRows(engine, table: "outbox")
        #expect(throws: (any Error).self) { try engine.loadBuiltInNotebookReview(scope: saved, now: now) }
        #expect(throws: (any Error).self) {
            try engine.submitBuiltInNotebookRating(submission(card, .good), card: card, action: action)
        }
        #expect(try exactRows(engine, table: "cards") == row)
        #expect(try exactRows(engine, table: "review_events") == events)
        #expect(try exactRows(engine, table: "outbox") == journal)
        #expect(try engine.cardStore.loadOptionalCardIncludingDeleted(workspaceId: saved.workspaceId,
            cardId: card.cardId)?.fsrsStability == 0.5)
    }

    @Test("The notebook queue excludes independent and merely linked Cards, and counts senses separately")
    func notebookOnlyQueueAndParticipation() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        let generic = try engine.saveCard(workspaceId: saved.workspaceId,
            input: .init(frontText: "Independent", backText: "No enrollment", tags: []), cardId: nil, mediaAssetIdsReadyForUpload: [])
        var content = try enroll(engine, saved: saved, selection: selection)
        let defaultID = try #require(content.queue.first).cardId
        #expect(content.queue.count == 1 && content.noteCards[defaultID] != nil)
        #expect(!content.queue.contains { $0.cardId == generic.cardId })
        #expect(content.statistics.activeSenses == 1 && content.statistics.exercises == 1)
        let baseline = content.review.groups[selection.senseID]?.cards
        try engine.setBuiltInNotebookReviewStatus(.paused, action: .init(content: content, selection: selection), requestID: UUID())
        content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        #expect(content.queue.isEmpty && content.statistics.pausedSenses == 1)
        #expect(content.review.groups[selection.senseID]?.cards == baseline)
        try engine.setBuiltInNotebookReviewStatus(.withdrawn, action: .init(content: content, selection: selection), requestID: UUID())
        content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        #expect(content.queue.isEmpty && content.statistics.withdrawnSenses == 1)
        try engine.setBuiltInNotebookReviewStatus(.active, action: .init(content: content, selection: selection), requestID: UUID())
        try fixture.reopen()
        content = try fixture.db.loadBuiltInNotebookReview(scope: saved, now: now)
        #expect(Set(content.queue.map(\.cardId)) == Set([defaultID]))
        #expect(try fixture.db.loadReviewEventCount() == 0)
    }

    @Test("Rating uses workspace settings; persisted causal undo keeps authored faces and append-only history")
    func ratingReopenAndUndo() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        var content = try enroll(engine, saved: saved, selection: selection)
        let original = try #require(content.queue.first)
        try engine.updateWorkspaceSchedulerSettings(workspaceId: saved.workspaceId, desiredRetention: 0.87,
            learningStepsMinutes: [3, 17], relearningStepsMinutes: [9], maximumIntervalDays: 500, enableFuzz: false)
        content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        #expect(content.schedulerSettings.learningStepsMinutes == [3, 17])
        let preview = try computeReviewSchedule(card: original, settings: content.schedulerSettings, rating: .again, now: now)
        let reviewed = try engine.submitBuiltInNotebookRating(submission(original, .again), card: original,
            action: .init(content: content, selection: selection))
        #expect(reviewed.dueAt.flatMap { parseIsoTimestamp(value: $0) } == preview.dueAt)
        #expect(reviewed.reps == 1)
        try fixture.reopen()
        content = try fixture.db.loadBuiltInNotebookReview(scope: saved, now: now)
        #expect(content.queue.isEmpty && content.statistics.ratingRecords == 1)
        let card = try #require(content.review.groups[selection.senseID]?.cards.first)
        let model = try #require(content.noteCards[card.cardId])
        var type = model.noteType; type.revision += 1
        type.templates[0].front = "Edited after rating"
        try fixture.db.saveReviewNoteType(type, expected: model.noteType, scope: saved)
        content = try fixture.db.loadBuiltInNotebookReview(scope: saved, now: now)
        let undo = try #require(content.undoByCardID[card.cardId])
        try fixture.db.undoBuiltInNotebookRating(undo, action: .init(content: content, selection: selection))
        let undone = try fixture.db.loadBuiltInNotebookReview(scope: saved, now: now)
        #expect(undone.queue.first?.reps == 0 && undone.queue.first?.frontText == "Edited after rating")
        #expect(undone.statistics.ratingRecords == 1 && undone.statistics.undoneRatings == 1)
        #expect(undone.recentHistory.first?.wasUndone == true && undone.undoByCardID.isEmpty)
        #expect(throws: (any Error).self) { try fixture.db.undoBuiltInNotebookRating(undo, action: .init(content: content, selection: selection)) }
    }

    @Test("Same-generation source/rating changes and account ABA reject old writes and old undo")
    func staleActionsFailClosed() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        var content = try enroll(engine, saved: saved, selection: selection)
        let oldAction = NotebookBuiltInReviewAction(content: content, selection: selection)
        let card = try #require(content.queue.first)
        _ = try engine.submitBuiltInNotebookRating(submission(card, .good), card: card, action: oldAction)
        let before = try rowCounts(engine)
        #expect(throws: (any Error).self) { try engine.setBuiltInNotebookReviewStatus(.paused, action: oldAction, requestID: UUID()) }
        #expect(try rowCounts(engine) == before)
        content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let staleUndo = try #require(content.undoByCardID[card.cardId])
        let firstRatingAction = NotebookBuiltInReviewAction(content: content, selection: selection)
        let current = try #require(content.review.groups[selection.senseID]?.cards.first)
        _ = try engine.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .easy,
            reviewedAtClient: formatIsoTimestamp(date: now.addingTimeInterval(20)), reviewedTimeZone: "UTC"),
            card: current, action: firstRatingAction)
        #expect(throws: (any Error).self) { try engine.undoBuiltInNotebookRating(staleUndo, action: firstRatingAction) }
        #expect(try engine.loadActiveCard(workspaceId: saved.workspaceId, cardId: card.cardId).reps == 2)
        let fresh = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let freshUndo = try #require(fresh.undoByCardID[card.cardId])
        let otherSelection = VocabularySelection(entryID: selection.entryID, senseID: saved.document.entries[0].senses[1].id)
        let beforeMismatchedUndo = try rowCounts(engine)
        #expect(throws: (any Error).self) {
            try engine.undoBuiltInNotebookRating(freshUndo, action: .init(content: fresh, selection: otherSelection))
        }
        #expect(try rowCounts(engine) == beforeMismatchedUndo)
        try engine.updateCloudSettings(cloudState: .linked, linkedUserId: "other-synthetic-owner",
            linkedWorkspaceId: saved.workspaceId, activeWorkspaceId: saved.workspaceId, linkedEmail: nil)
        try engine.updateCloudSettings(cloudState: .linked, linkedUserId: fixture.owner,
            linkedWorkspaceId: saved.workspaceId, activeWorkspaceId: saved.workspaceId, linkedEmail: nil)
        let afterSwitch = try rowCounts(engine)
        #expect(throws: (any Error).self) { try engine.undoBuiltInNotebookRating(freshUndo, action: .init(content: fresh, selection: selection)) }
        #expect(try rowCounts(engine) == afterSwitch)
        let freshScope = try engine.loadLingroveNotebook(workspaceId: saved.workspaceId)
        #expect(freshScope.generation != saved.generation)
        #expect(try engine.loadActiveCard(workspaceId: saved.workspaceId, cardId: card.cardId).reps == 2)
    }


    private func source(_ fixture: NotebookMediaDatabaseFixture) throws -> (LingroveNotebookSnapshot, VocabularySelection) {
        let saved = try fixture.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        return (saved, .init(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id))
    }

    private func enroll(_ engine: LingroveNotebookEngine, saved: LingroveNotebookSnapshot,
                        selection: VocabularySelection) throws -> NotebookBuiltInReviewSnapshot {
        let content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        _ = try engine.enrollReviewNotes(selections: [selection], type: content.defaultNoteType, scope: saved)
        return try engine.loadBuiltInNotebookReview(scope: saved, now: now)
    }

    private func submission(_ card: Card, _ rating: ReviewRating) -> ReviewSubmission {
        .init(cardId: card.cardId, rating: rating, reviewedAtClient: formatIsoTimestamp(date: now), reviewedTimeZone: "Asia/Shanghai")
    }

    private func rowCounts(_ engine: LingroveNotebookEngine) throws -> [Int] {
        try ["cards", "notebook_review_enrollments", "notebook_review_exercises", "notebook_card_links",
             "notebook_review_operations", "notebook_card_link_operations", "notebook_review_requests", "review_events", "notebook_review_undo"]
            .map { try engine.core.scalarInt(sql: "SELECT COUNT(*) FROM " + $0, values: []) }
    }

    private func exactRows(_ engine: LingroveNotebookEngine, table: String) throws -> [[String]] {
        let columns = try engine.core.query(sql: "PRAGMA table_info(" + table + ")", values: []) {
            DatabaseCore.columnText(statement: $0, index: 1)
        }
        let projection = columns.map { "quote(" + $0 + ")" }.joined(separator: ",")
        return try engine.core.query(sql: "SELECT " + projection + " FROM " + table + " ORDER BY rowid", values: []) { row in
            columns.indices.map { DatabaseCore.columnText(statement: row, index: Int32($0)) }
        }
    }
}
