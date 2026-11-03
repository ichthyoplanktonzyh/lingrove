import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

/// Real SQLite integration tests bind full retained history, participation and schedule to the
/// same notebook scope. No server, ordinary user database, UI counter or demo series is used.
@MainActor
struct NotebookProgressIntegrationTests {
    private let now = parseIsoTimestamp(value: "2026-11-03T12:00:00.000Z")!

    @Test("A native read-only handle does not bootstrap a missing notebook or create files")
    func readOnlyEmptyAndMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("progress-empty-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite")
        let media = directory.appendingPathComponent("media")
        let writer = try LingroveNotebookEngine(databaseURL: url, mediaDirectoryURL: media)
        defer { try? writer.close() }
        let reader = try LingroveNotebookEngine(readOnlyDatabaseURL: url, mediaDirectoryURL: media)
        defer { try? reader.close() }
        let scope = try reader.notebookProgressReadFence().scope
        #expect(scope.notebookID == nil)
        let empty = try reader.loadNotebookProgress(scope: scope, now: now, calendar: utc())
        #expect(!empty.hasHistory && empty.schedule.totalCards == 0 && empty.summary.currentStreakDays == 0)
        #expect(empty.summary.streakFreeze.availableCredits == 0 && empty.summary.streakFreeze.capacity == 0)
        #expect(try reader.core.scalarInt(sql: "SELECT total_changes()", values: []) == 0)
        #expect(throws: (any Error).self) {
            try reader.core.execute(sql: "UPDATE app_local_settings SET active_workspace_id=NULL", values: [])
        }
        #expect(try writer.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_state", values: []) == 0)
        let absent = directory.appendingPathComponent("absent/subdirectory/notebook.sqlite")
        #expect(throws: (any Error).self) {
            try LingroveNotebookEngine(readOnlyDatabaseURL: absent, mediaDirectoryURL: absent.deletingLastPathComponent())
        }
        #expect(!FileManager.default.fileExists(atPath: absent.deletingLastPathComponent().path))
    }

    @Test("Full history exceeds the recent list; undo and re-rating count each effective event once")
    func completeHistoryUndoAndGenericExclusion() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        try enroll(engine, saved: saved, selection: selection)
        for index in 0..<20 {
            let content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
            let card = try #require(content.review.groups[selection.senseID]?.cards.first)
            _ = try engine.submitBuiltInNotebookRating(.init(cardId: card.cardId,
                rating: ReviewRating.allCases[index % 4],
                reviewedAtClient: formatIsoTimestamp(date: now.addingTimeInterval(Double(index - 20) * 3_600)),
                reviewedTimeZone: "UTC"), card: card, action: .init(content: content, selection: selection))
        }
        var content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        #expect(content.recentHistory.count == 12)
        var progress = try read(engine)
        #expect(progress.totalReviews == 20 && progress.dailyReviews.reduce(0, { $0 + $1.reviewCount }) == 20)
        #expect(progress.dailyReviews.reduce(0, { $0 + $1.againCount }) == 5)
        #expect(progress.dailyReviews.reduce(0, { $0 + $1.easyCount }) == 5)
        let card = try #require(content.review.groups[selection.senseID]?.cards.first)
        try engine.undoBuiltInNotebookRating(try #require(content.undoByCardID[card.cardId]),
            action: .init(content: content, selection: selection))
        progress = try read(engine)
        #expect(progress.totalReviews == 19 && progress.undoneReviews == 1)
        #expect(progress.dailyReviews.reduce(0, { $0 + $1.easyCount }) == 4)
        content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let current = try #require(content.review.groups[selection.senseID]?.cards.first)
        _ = try engine.submitBuiltInNotebookRating(.init(cardId: current.cardId, rating: .easy,
            reviewedAtClient: formatIsoTimestamp(date: now.addingTimeInterval(-10)), reviewedTimeZone: "UTC"),
            card: current, action: .init(content: content, selection: selection))
        let generic = try engine.saveCard(workspaceId: saved.workspaceId,
            input: .init(frontText: "Independent card", backText: "Excluded", tags: []),
            cardId: nil, mediaAssetIdsReadyForUpload: [])
        _ = try engine.submitReview(workspaceId: saved.workspaceId, reviewSubmission: .init(cardId: generic.cardId,
            rating: .good, reviewedAtClient: formatIsoTimestamp(date: now), reviewedTimeZone: "UTC"))
        let otherSelection = VocabularySelection(entryID: selection.entryID,
            senseID: saved.document.entries[0].senses[1].id)
        let linked = try engine.saveNewLingroveNotebookCard(draft: LingroveNotebookCardMaterial.draft(
            snapshot: saved, selection: otherSelection), input: .init(frontText: "Linked only", backText: "Excluded", tags: []),
            mediaAssetIdsReadyForUpload: [])
        _ = try engine.submitReview(workspaceId: saved.workspaceId, reviewSubmission: .init(cardId: linked.cardId,
            rating: .easy, reviewedAtClient: formatIsoTimestamp(date: now), reviewedTimeZone: "UTC"))
        try fixture.reopen()
        progress = try read(fixture.db)
        #expect(progress.totalReviews == 20 && progress.undoneReviews == 1)
        #expect(progress.exercises == 1 && progress.activeSenses == 1)
        #expect(progress.dailyReviews.allSatisfy { $0.reviewCount == $0.againCount + $0.hardCount + $0.goodCount + $0.easyCount })
    }

    @Test("Pause, withdrawal, missing source and deleted Card retain history while forecast follows real admission")
    func participationAndRetainedHistory() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        try enroll(engine, saved: saved, selection: selection)
        var content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        var card = try #require(content.review.groups[selection.senseID]?.cards.first)
        _ = try engine.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: formatIsoTimestamp(date: now), reviewedTimeZone: "UTC"), card: card,
            action: .init(content: content, selection: selection))
        for status in [LingroveNotebookReviewStatus.paused, .withdrawn, .active] {
            content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
            try engine.setBuiltInNotebookReviewStatus(status, action: .init(content: content, selection: selection), requestID: UUID())
            let progress = try read(engine)
            #expect(progress.totalReviews == 1)
            #expect(progress.schedule.totalCards == (status == .active ? 1 : 0))
        }
        let removed = try engine.saveLingroveNotebook(VocabularyDocument(), basedOn: saved, restoringBackup: true)
        #expect(try read(engine).totalReviews == 1 && read(engine).schedule.totalCards == 0)
        content = try engine.loadBuiltInNotebookReview(scope: removed, now: now)
        card = try #require(content.review.groups[selection.senseID]?.cards.first)
        let link = try #require(content.review.links.first { $0.cardId == card.cardId })
        try engine.retainNotebookExercise(link: link, card: card, snapshot: removed,
            action: .init(content: content, selection: selection))
        #expect(try read(engine).schedule.totalCards == 1)
        _ = try engine.deleteCard(workspaceId: saved.workspaceId, cardId: card.cardId)
        let deleted = try read(engine)
        #expect(deleted.totalReviews == 1 && deleted.schedule.totalCards == 0 && deleted.exercises == 0)
        #expect(deleted.enrolledSenses == 1)
    }

    @Test("Merge counts one sense and preserves separate exercises and both original histories")
    func mergedSourcesPreserveAllEvents() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, first) = try source(fixture)
        let engine = fixture.db
        let entry = saved.document.entries[0]
        let second = VocabularySelection(entryID: entry.id, senseID: entry.senses[1].id)
        for selection in [first, second] {
            try enroll(engine, saved: saved, selection: selection)
            let content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
            let card = try #require(content.review.groups[selection.senseID]?.cards.first)
            _ = try engine.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .hard,
                reviewedAtClient: formatIsoTimestamp(date: now), reviewedTimeZone: "UTC"), card: card,
                action: .init(content: content, selection: selection))
        }
        var document = saved.document
        var sense = entry.senses[0]
        sense.mergedFrom = [entry.senses[1].id]
        document.entries[0].senses = [sense]
        _ = try engine.saveLingroveNotebook(document, basedOn: saved, restoringBackup: true)
        let progress = try read(engine)
        #expect(progress.totalReviews == 2 && progress.exercises == 2 && progress.schedule.totalCards == 2)
        #expect(progress.enrolledSenses == 1 && progress.activeSenses == 1)
        #expect(progress.dailyReviews.reduce(0, { $0 + $1.hardCount }) == 2)
    }

    @Test("Full-history streaks survive the bounded chart and never invent freeze credits")
    func longHistoryAndRecordedTimeZoneDays() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        try enroll(engine, saved: saved, selection: selection)
        // Persist actual ratings, including an old run outside the 140-day display range.
        let dates = ["2025-01-01T12:00:00Z", "2025-01-02T12:00:00Z", "2025-01-03T12:00:00Z",
                     "2026-11-01T06:30:00Z", "2026-11-02T07:30:00Z", "2026-11-03T07:30:00Z"]
        for date in dates {
            let content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
            let card = try #require(content.review.groups[selection.senseID]?.cards.first)
            _ = try engine.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .again,
                reviewedAtClient: date, reviewedTimeZone: "America/Los_Angeles"), card: card,
                action: .init(content: content, selection: selection))
        }
        let progress = try read(engine)
        #expect(progress.totalReviews == 6 && progress.dailyReviews.reduce(0, { $0 + $1.reviewCount }) == 3)
        #expect(progress.summary.longestStreakDays == 3 && progress.summary.currentStreakDays == 3)
        #expect(progress.summary.activeReviewDays == 6 && !progress.summary.hasReviewedToday)
        #expect(progress.summary.streakFreeze.capacity == 0 && !progress.streakDays.contains { $0.state == .frozen })
    }

    @Test("All eight schedule ranges use local midnight across the DST boundary")
    func forecastBoundariesUseCivilDays() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        let reference = try #require(parseIsoTimestamp(value: "2026-03-07T20:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        try enroll(engine, saved: saved, selection: selection)
        for _ in 0..<7 {
            let content = try engine.loadBuiltInNotebookReview(scope: saved, now: reference)
            let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
            _ = try engine.addBuiltInNotebookExercise(draft, input: draft.generatedContent,
                action: .init(content: content, selection: selection))
        }
        let initial = try engine.loadBuiltInNotebookReview(scope: saved, now: reference)
        let cards = try #require(initial.review.groups[selection.senseID]?.cards)
        let start = calendar.startOfDay(for: reference)
        for (card, offset) in zip(cards, [0, 1, 8, 31, 91, 361, 721]) {
            let content = try engine.loadBuiltInNotebookReview(scope: saved, now: reference)
            let current = try #require(content.review.groups[selection.senseID]?.cards.first { $0.cardId == card.cardId })
            _ = try engine.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
                reviewedAtClient: formatIsoTimestamp(date: reference), reviewedTimeZone: calendar.timeZone.identifier),
                card: current, action: .init(content: content, selection: selection))
            let due = try #require(calendar.date(byAdding: .day, value: offset, to: start))
            try engine.core.execute(sql: "UPDATE cards SET due_at=?,due_at_millis=? WHERE workspace_id=? AND card_id=?",
                values: [.text(formatIsoTimestamp(date: due)), .integer(Int64(due.timeIntervalSince1970 * 1_000)),
                    .text(saved.workspaceId), .text(card.cardId)])
        }
        let scope = try engine.notebookProgressReadFence().scope
        let progress = try engine.loadNotebookProgress(scope: scope, now: reference, calendar: calendar)
        #expect(progress.schedule.buckets.map(\.key) == ReviewScheduleBucketKey.stableOrder)
        #expect(progress.schedule.buckets.map(\.count) == Array(repeating: 1, count: 8))
        #expect(progress.schedule.totalCards == 8)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let after = try #require(calendar.date(byAdding: .day, value: 1, to: tomorrow))
        #expect(after.timeIntervalSince(tomorrow) == 23 * 3_600)
    }

    @Test("Same-revision ratings, external commits and account ABA invalidate publication fences")
    func scopeAndConnectionFences() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (saved, selection) = try source(fixture)
        let engine = fixture.db
        try enroll(engine, saved: saved, selection: selection)
        let before = try engine.notebookProgressReadFence()
        let other = try LingroveNotebookEngine(databaseURL: fixture.url, mediaDirectoryURL: engine.core.mediaDirectoryURL)
        defer { try? other.close() }
        let content = try other.loadBuiltInNotebookReview(scope: saved, now: now)
        let card = try #require(content.review.groups[selection.senseID]?.cards.first)
        _ = try other.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: formatIsoTimestamp(date: now), reviewedTimeZone: "UTC"), card: card,
            action: .init(content: content, selection: selection))
        let after = try engine.notebookProgressReadFence()
        #expect(before.scope == after.scope && before != after)
        #expect(try read(engine).totalReviews == 1)
        let secondWorkspace = UUID().uuidString.lowercased()
        try fixture.addWorkspace(secondWorkspace)
        try engine.updateCloudSettings(cloudState: .linked, linkedUserId: "different-owner",
            linkedWorkspaceId: secondWorkspace, activeWorkspaceId: secondWorkspace, linkedEmail: nil)
        #expect(try read(engine).totalReviews == 0)
        #expect(throws: (any Error).self) { try engine.loadNotebookProgress(scope: before.scope, now: now, calendar: utc()) }
        try engine.updateCloudSettings(cloudState: .linked, linkedUserId: fixture.owner,
            linkedWorkspaceId: saved.workspaceId, activeWorkspaceId: saved.workspaceId, linkedEmail: nil)
        let returned = try engine.notebookProgressReadFence()
        #expect(returned.scope.workspaceID == before.scope.workspaceID && returned.scope.generation != before.scope.generation)
        #expect(throws: (any Error).self) { try engine.loadNotebookProgress(scope: before.scope, now: now, calendar: utc()) }
    }

    private func source(_ fixture: NotebookMediaDatabaseFixture) throws -> (LingroveNotebookSnapshot, VocabularySelection) {
        let saved = try fixture.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        return (saved, .init(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id))
    }

    private func enroll(_ engine: LingroveNotebookEngine, saved: LingroveNotebookSnapshot,
                        selection: VocabularySelection) throws {
        let content = try engine.loadBuiltInNotebookReview(scope: saved, now: now)
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
        _ = try engine.enrollBuiltInNotebookSense(draft, input: draft.generatedContent,
            action: .init(content: content, selection: selection))
    }

    private func read(_ engine: LingroveNotebookEngine) throws -> NotebookProgressSnapshot {
        try engine.loadNotebookProgress(scope: engine.notebookProgressReadFence().scope, now: now, calendar: utc())
    }

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
