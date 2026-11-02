import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

/// Actual SQLite checks for the native notebook entrance. They exercise shared commands and
/// durable rows, including failed-action rollback, rather than a mock scheduler or UI counters.
@MainActor
struct BuiltInNotebookReviewIntegrationTests {
    private let now = Date(timeIntervalSince1970: 1_793_664_000)

    @Test("Exact committed intents replay without reactivating a later participation choice")
    func exactReplayRetainsCurrentState() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        let initial = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
        let initialAction = NotebookBuiltInReviewAction(content: initial, selection: selection)
        let first = try engine.enrollBuiltInNotebookSense(draft, input: draft.generatedContent, action: initialAction)
        let beforeReplay = try rowCounts(engine)
        #expect(try engine.enrollBuiltInNotebookSense(draft, input: draft.generatedContent, action: initialAction) == first)
        #expect(try rowCounts(engine) == beforeReplay)
        let enrolled = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let additionalDraft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
        let additionalAction = NotebookBuiltInReviewAction(content: enrolled, selection: selection)
        let added = try engine.addBuiltInNotebookExercise(additionalDraft, input: additionalDraft.generatedContent, action: additionalAction)
        #expect(try engine.addBuiltInNotebookExercise(additionalDraft,
            input: additionalDraft.generatedContent, action: additionalAction).cardId == added.cardId)
        var content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let pauseAction = NotebookBuiltInReviewAction(content: content, selection: selection)
        let pauseID = UUID()
        try engine.setBuiltInNotebookReviewStatus(.paused, action: pauseAction, requestID: pauseID)
        content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        try engine.setBuiltInNotebookReviewStatus(.active, action: .init(content: content, selection: selection), requestID: UUID())
        let beforeStatusReplay = try rowCounts(engine)
        try engine.setBuiltInNotebookReviewStatus(.paused, action: pauseAction, requestID: pauseID)
        content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        #expect(content.review.groups[selection.senseID]?.status == .active && content.statistics.exercises == 2)
        #expect(try rowCounts(engine) == beforeStatusReplay)
        #expect(throws: (any Error).self) {
            try engine.enrollBuiltInNotebookSense(draft, input: .init(frontText: "changed intent", backText: "", tags: []), action: initialAction)
        }
    }

    @Test("Opening/preparing is read-only; explicit authored enrollment commits atomically")
    func explicitEnrollmentAndAtomicPreparation() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        let before = try rowCounts(engine)
        let content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let prepared = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
        #expect(content.queue.isEmpty && content.statistics.exercises == 0)
        #expect(try rowCounts(engine) == before)
        let action = NotebookBuiltInReviewAction(content: content, selection: selection)
        #expect(throws: (any Error).self) {
            try engine.enrollBuiltInNotebookSense(prepared, input: .init(frontText: "", backText: "invalid", tags: []), action: action)
        }
        #expect(try rowCounts(engine) == before)
        let authored = CardEditorInput(frontText: "My own question", backText: prepared.generatedContent.backText, tags: ["authored"])
        _ = try engine.enrollBuiltInNotebookSense(prepared, input: authored, action: action)
        let committedRows = try rowCounts(engine)
        _ = try engine.enrollBuiltInNotebookSense(prepared, input: authored, action: action)
        #expect(try rowCounts(engine) == committedRows)
        let enrolled = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let card = try #require(enrolled.queue.first)
        #expect(card.frontText == authored.frontText && card.backText == authored.backText && card.reps == 0)
        #expect(enrolled.statistics.activeSenses == 1 && enrolled.statistics.exercises == 1 && enrolled.statistics.readyExercises == 1)
        #expect(enrolled.review.links.first?.generatedContent == prepared.generatedContent)
        #expect(try engine.loadLingroveNotebook(workspaceId: saved.workspaceId) == saved)
        try fixture.reopen()
        #expect(try fixture.db.loadBuiltInNotebookReview(scope: saved, now: now).queue.first?.cardId == card.cardId)
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
        let other = saved.document.entries[0].senses[1]
        let merelyLinked = try engine.saveNewLingroveNotebookCard(
            draft: LingroveNotebookCardMaterial.draft(snapshot: saved, selection: .init(entryID: selection.entryID, senseID: other.id)),
            input: .init(frontText: "Linked only", backText: "Not selected", tags: []), mediaAssetIdsReadyForUpload: [])
        var content = try enroll(engine, saved: saved, selection: selection)
        let defaultID = try #require(content.queue.first).cardId
        let extra = try engine.addBuiltInNotebookExercise(LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection),
            input: .init(frontText: "Second question", backText: "Same sense", tags: []),
            action: .init(content: content, selection: selection))
        content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        #expect(Set(content.queue.map(\.cardId)) == Set([defaultID, extra.cardId]))
        #expect(!content.queue.contains { $0.cardId == generic.cardId || $0.cardId == merelyLinked.cardId })
        #expect(content.statistics.activeSenses == 1 && content.statistics.exercises == 2)
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
        #expect(Set(content.queue.map(\.cardId)) == Set([defaultID, extra.cardId]))
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
        let link = try #require(content.review.links.first { $0.cardId == card.cardId })
        try fixture.db.prepareNotebookExercise(link: link, card: card, snapshot: saved, exampleID: nil,
            input: .init(frontText: "Edited after rating", backText: card.backText, tags: card.tags),
            action: .init(content: content, selection: selection))
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
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
        _ = try engine.submitBuiltInNotebookRating(submission(card, .good), card: card, action: oldAction)
        let before = try rowCounts(engine)
        #expect(throws: (any Error).self) { try engine.addBuiltInNotebookExercise(draft, input: draft.generatedContent, action: oldAction) }
        #expect(throws: (any Error).self) { try engine.setBuiltInNotebookReviewStatus(.paused, action: oldAction, requestID: UUID()) }
        let staleLink = try #require(content.review.links.first { $0.cardId == card.cardId })
        #expect(throws: (any Error).self) {
            try engine.prepareNotebookExercise(link: staleLink, card: card, snapshot: saved, exampleID: nil,
                input: .init(frontText: "stale edit", backText: "stale", tags: []), action: oldAction)
        }
        #expect(throws: (any Error).self) {
            try engine.retainNotebookExercise(link: staleLink, card: card, snapshot: saved, action: oldAction)
        }
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
        #expect(throws: (any Error).self) { try engine.addBuiltInNotebookExercise(draft, input: draft.generatedContent, action: oldAction) }
        #expect(try rowCounts(engine) == afterSwitch)
        let freshScope = try engine.loadLingroveNotebook(workspaceId: saved.workspaceId)
        #expect(freshScope.generation != saved.generation)
        #expect(try engine.loadActiveCard(workspaceId: saved.workspaceId, cardId: card.cardId).reps == 2)
    }

    @Test("Source refresh is three-way; missing and returning sources preserve retained memory")
    func materialRefreshRetainAndSourceReturn() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        let initial = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
        _ = try engine.enrollBuiltInNotebookSense(draft,
            input: .init(frontText: "Authored question", backText: draft.generatedContent.backText, tags: draft.generatedContent.tags),
            action: .init(content: initial, selection: selection))
        var content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let card = try #require(content.queue.first)
        _ = try engine.submitBuiltInNotebookRating(submission(card, .good), card: card,
            action: .init(content: content, selection: selection))
        let rated = try engine.loadActiveCard(workspaceId: saved.workspaceId, cardId: card.cardId)
        var changedDocument = saved.document
        changedDocument.entries[0].senses[0].meaning = "new generated answer"
        let changed = try engine.saveLingroveNotebook(changedDocument, basedOn: saved, restoringBackup: true)
        let updated = try engine.loadActiveCard(workspaceId: saved.workspaceId, cardId: card.cardId)
        #expect(updated.frontText == "Authored question" && updated.backText == "new generated answer")
        #expect(updated.reps == rated.reps && updated.dueAt == rated.dueAt)
        let removed = try engine.saveLingroveNotebook(VocabularyDocument(), basedOn: changed, restoringBackup: true)
        content = try engine.loadBuiltInNotebookReview(scope: removed, now: now)
        #expect(content.review.groups.count == 1 && !content.eligibleCardIDs.contains(card.cardId))
        let link = try #require(content.review.links.first { $0.cardId == card.cardId })
        let baseline = try #require(content.review.groups[selection.senseID]?.cards.first)
        try engine.retainNotebookExercise(link: link, card: baseline, snapshot: removed,
            action: .init(content: content, selection: selection))
        content = try engine.loadBuiltInNotebookReview(scope: removed, now: now)
        #expect(content.eligibleCardIDs.contains(card.cardId))
        let retainedLink = try #require(content.review.links.first { $0.cardId == card.cardId })
        try engine.saveRetainedBuiltInNotebookMaterial(link: retainedLink, card: baseline,
            input: .init(frontText: "Saved material edit", backText: baseline.backText, tags: baseline.tags),
            action: .init(content: content, selection: selection))
        var returningDocument = changed.document
        returningDocument.entries[0].senses[0].meaning = "answer after source returns"
        let returned = try engine.saveLingroveNotebook(returningDocument, basedOn: removed, restoringBackup: true)
        try fixture.reopen()
        content = try fixture.db.loadBuiltInNotebookReview(scope: returned, now: now)
        let restored = try #require(content.review.groups[selection.senseID]?.cards.first)
        #expect(restored.frontText == "Saved material edit" && restored.reps == rated.reps && restored.dueAt == rated.dueAt)
        #expect(restored.backText == "answer after source returns")
        #expect(content.statistics.ratingRecords == 1 && content.eligibleCardIDs.contains(card.cardId))
        #expect(try fixture.db.core.scalarInt(sql: "SELECT COUNT(*) FROM pragma_foreign_key_check", values: []) == 0)
    }

    private func source(_ fixture: NotebookMediaDatabaseFixture) throws -> (LingroveNotebookSnapshot, VocabularySelection) {
        let saved = try fixture.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        return (saved, .init(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id))
    }

    private func enroll(_ engine: LingroveNotebookEngine, saved: LingroveNotebookSnapshot,
                        selection: VocabularySelection) throws -> NotebookBuiltInReviewSnapshot {
        let content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
        _ = try engine.enrollBuiltInNotebookSense(draft, input: draft.generatedContent, action: .init(content: content, selection: selection))
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
