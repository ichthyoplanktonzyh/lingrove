import AppKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// App-level reads use the production read-only actor and real disposable SQLite files. A
/// controllable reader only delays delivery; it never fabricates a statistic or bypasses SQL.
@Suite(.serialized)
@MainActor
struct NotebookProgressModelIntegrationTests {
    @Test("Empty, rating, undo, hidden changes and re-entry all load from the same saved notebook")
    func actualWritesRefreshAndReenter() async throws {
        let fixture = try NotebookProgressMacFixture(); defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.setActive(false) }
        model.setActive(true)
        await model.waitForIdle()
        #expect(try loaded(model).snapshot.totalReviews == 0)
        #expect(try loaded(model).snapshot.schedule.totalCards == 0)
        try fixture.enroll()
        try fixture.rate(.good)
        fixture.repository.publishChange()
        #expect(isLoading(model))
        await model.waitForIdle()
        #expect(try loaded(model).snapshot.totalReviews == 1)
        let content = try fixture.review()
        let card = try #require(content.review.groups[fixture.selection.senseID]?.cards.first)
        try fixture.repository.engine.undoBuiltInNotebookRating(try #require(content.undoByCardID[card.cardId]),
            action: .init(content: content, selection: fixture.selection))
        fixture.repository.publishChange()
        await model.waitForIdle()
        #expect(try loaded(model).snapshot.totalReviews == 0 && loaded(model).snapshot.undoneReviews == 1)
        model.setActive(false)
        try fixture.rate(.easy)
        fixture.repository.publishChange()
        #expect(isInactive(model))
        model.setActive(true)
        await model.waitForIdle()
        #expect(try loaded(model).snapshot.totalReviews == 1 && loaded(model).snapshot.undoneReviews == 1)
    }

    @Test("A late SQL result cannot publish after deactivation or account ABA")
    func lateResultsAreRevoked() async throws {
        let fixture = try NotebookProgressMacFixture(); defer { fixture.cleanUp() }
        try fixture.enroll()
        try fixture.rate(.good)
        let gate = NotebookProgressReadGate(io: fixture.io())
        let model = fixture.model(reader: gate)
        defer { model.setActive(false) }
        model.setActive(true)
        try await gate.waitUntilCaptured()
        model.setActive(false)
        await gate.release()
        await model.waitForIdle()
        #expect(isInactive(model))
        await gate.pauseNextRead()
        model.setActive(true)
        try await gate.waitUntilCaptured()
        let old = try fixture.repository.engine.notebookProgressReadFence().scope
        let other = try fixture.addEmptyWorkspace()
        try fixture.repository.engine.updateCloudSettings(cloudState: .linked, linkedUserId: "progress-other-owner",
            linkedWorkspaceId: other, activeWorkspaceId: other, linkedEmail: nil)
        // No Combine notification: the final durable publication fence must catch this itself.
        await gate.release()
        await model.waitForIdle()
        #expect(try loaded(model).snapshot.scope.workspaceID == other && loaded(model).snapshot.totalReviews == 0)
        try fixture.repository.engine.updateCloudSettings(cloudState: .disconnected, linkedUserId: nil,
            linkedWorkspaceId: nil, activeWorkspaceId: old.workspaceID, linkedEmail: nil)
        fixture.repository.publishChange()
        await model.waitForIdle()
        #expect(try loaded(model).snapshot.scope.generation != old.generation)
        #expect(try loaded(model).snapshot.totalReviews == 1)
    }

    @Test("A same-generation external rating during and after a read triggers a fresh SQL snapshot")
    func externalCommitFencesAndProbe() async throws {
        let fixture = try NotebookProgressMacFixture(); defer { fixture.cleanUp() }
        try fixture.enroll()
        try fixture.rate(.hard)
        let gate = NotebookProgressReadGate(io: fixture.io())
        let model = fixture.model(reader: gate)
        defer { model.setActive(false) }
        model.setActive(true)
        try await gate.waitUntilCaptured()
        let external = try LingroveNotebookEngine(databaseURL: fixture.repository.databaseURL,
            mediaDirectoryURL: fixture.repository.mediaDirectoryURL)
        defer { try? external.close() }
        try fixture.rate(.good, engine: external, offset: 10)
        await gate.release()
        await model.waitForIdle()
        #expect(try loaded(model).snapshot.totalReviews == 2)
        let generation = try loaded(model).snapshot.scope.generation
        try fixture.rate(.easy, engine: external, offset: 20)
        model.checkForStorageChanges()
        await model.waitForIdle()
        #expect(try loaded(model).snapshot.totalReviews == 3 && loaded(model).snapshot.scope.generation == generation)
    }

    @Test("Read failure is an explicit retryable error, then the real empty store loads")
    func errorAndRetry() async throws {
        let fixture = try NotebookProgressMacFixture(); defer { fixture.cleanUp() }
        let reader = NotebookProgressFailureOnceReader(io: fixture.io())
        let model = fixture.model(reader: reader)
        defer { model.setActive(false) }
        model.setActive(true)
        await model.waitForIdle()
        guard case .failed = model.state else { Issue.record("Read failure did not produce an error state"); return }
        try await capture(NotebookProgressDestination(model: model), name: "progress-error", size: .init(width: 860, height: 560))
        model.reload()
        await model.waitForIdle()
        #expect(try loaded(model).snapshot.totalReviews == 0)
        try await capture(NotebookProgressDestination(model: model), name: "progress-empty", size: .init(width: 860, height: 980))
    }

    @Test("Native personal calendar, rating chart and schedule render actual saved data")
    func nativeChartRendering() async throws {
        let fixture = try NotebookProgressMacFixture(); defer { fixture.cleanUp() }
        try fixture.enroll()
        for (index, rating) in ReviewRating.allCases.enumerated() {
            try fixture.rate(rating, offset: Double(index) * 60)
        }
        try fixture.populateForecastRanges()
        let model = fixture.model()
        defer { model.setActive(false) }
        model.setActive(true)
        await model.waitForIdle()
        let content = try loaded(model)
        #expect(content.snapshot.totalReviews == 10 && content.streakWeeks.count == 5)
        #expect(content.snapshot.schedule.buckets.map(\.count) == Array(repeating: 1, count: 8))
        #expect(content.chartDays.count == recentProgressHistoryDayCount)
        #expect(content.snapshot.dailyReviews.reduce(0, { $0 + $1.againCount }) == 1)
        let pages = makeNotebookProgressReviewChartPages(chartDays: content.chartDays,
            calendar: content.snapshot.calendar, today: content.snapshot.now)
        #expect(pages.allSatisfy { $0.days.count == 7 })
        try await capture(NotebookProgressDestination(model: model), name: "progress-loaded", size: .init(width: 860, height: 1600))
        try await capture(NotebookProgressReviewsSection(chartDays: content.chartDays,
            chartCalendar: content.snapshot.calendar, selectionResetKey: content.snapshot.scope.generation)
            .padding(24).tint(.orange), name: "progress-rating-chart", size: .init(width: 700, height: 540))
        try await capture(NotebookProgressReviewScheduleSection(schedule: content.snapshot.schedule)
            .padding(24).tint(.orange), name: "progress-schedule-chart", size: .init(width: 700, height: 650))
    }

    private func loaded(_ model: NotebookProgressModel) throws -> NotebookProgressContent {
        guard case let .loaded(content) = model.state else {
            Issue.record("Expected an actual SQL-backed loaded snapshot")
            throw NotebookProgressTestError.unexpectedState
        }
        return content
    }

    private func isLoading(_ model: NotebookProgressModel) -> Bool {
        if case .loading = model.state { return true }
        return false
    }

    private func isInactive(_ model: NotebookProgressModel) -> Bool {
        if case .inactive = model.state { return true }
        return false
    }

    private func capture(_ content: some View, name: String, size: CGSize) async throws {
        guard let path = ProcessInfo.processInfo.environment["LINGROVE_PROGRESS_EVIDENCE_DIR"] else { return }
        let window = NSWindow(contentRect: .init(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        window.setFrameOrigin(.init(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_000 && view.bounds.width >= size.width)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

private enum NotebookProgressTestError: Error { case syntheticReadFailure, unexpectedState }

/// The actor deliberately ignores delivery cancellation once it has captured real data. This
/// models a native operation that cannot stop instantly and exercises the model's late guard.
private actor NotebookProgressReadGate: NotebookProgressReading {
    private let io: NotebookProgressIO
    private var shouldPause = true
    private var captured = false
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var delivery: CheckedContinuation<Void, Never>?
    private var readError: (any Error)?

    init(io: NotebookProgressIO) { self.io = io }

    func load(scope: NotebookProgressScope, now: Date, calendar: Calendar) async throws -> NotebookProgressContent {
        let content: NotebookProgressContent
        do { content = try await io.load(scope: scope, now: now, calendar: calendar) } catch {
            readError = error
            let waiting = waiters
            waiters.removeAll()
            waiting.forEach { $0.resume(throwing: error) }
            throw error
        }
        if shouldPause {
            shouldPause = false
            captured = true
            let waiting = waiters
            waiters.removeAll()
            waiting.forEach { $0.resume() }
            await withCheckedContinuation { delivery = $0 }
        }
        return content
    }

    func waitUntilCaptured() async throws {
        if let readError { throw readError }
        if captured { return }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func release() { delivery?.resume(); delivery = nil }
    func pauseNextRead() { captured = false; shouldPause = true; readError = nil }
}

private actor NotebookProgressFailureOnceReader: NotebookProgressReading {
    private let io: NotebookProgressIO
    private var fail = true
    init(io: NotebookProgressIO) { self.io = io }

    func load(scope: NotebookProgressScope, now: Date, calendar: Calendar) async throws -> NotebookProgressContent {
        if fail { fail = false; throw NotebookProgressTestError.syntheticReadFailure }
        return try await io.load(scope: scope, now: now, calendar: calendar)
    }
}

/// One private directory and app repository per test. No Keychain, preferences, production app,
/// sync, network or global keyboard monitor is constructed by the fixture.
@MainActor
private final class NotebookProgressMacFixture {
    let directory: URL
    let repository: MacNotebookRepository
    let selection: VocabularySelection
    let referenceNow = parseIsoTimestamp(value: "2026-11-03T12:00:00Z")!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-progress-w4-" + UUID().uuidString)
        repository = try .init(databaseURL: directory.appendingPathComponent("notebook.sqlite"),
            mediaDirectoryURL: directory.appendingPathComponent("media"))
        let date = referenceNow
        let sense = VocabularySense(id: UUID(), meaning: "a sheltered place", meaningLanguage: .english,
            examples: [], isSavedWithoutContext: true, createdAt: date, updatedAt: date)
        let entry = VocabularyEntry(id: UUID(), expression: "harbor", dictionaryForm: "harbor", language: .english,
            kind: .word, senses: [sense], createdAt: date, updatedAt: date)
        selection = .init(entryID: entry.id, senseID: sense.id)
        _ = try repository.engine.saveLingroveNotebook(.init(entries: [entry]), basedOn: repository.snapshot())
    }

    func model(reader: (any NotebookProgressReading)? = nil) -> NotebookProgressModel {
        let date = referenceNow
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return .init(repository: repository, reader: reader, now: { date }, calendar: { calendar })
    }

    func io() -> NotebookProgressIO {
        .init(databaseURL: repository.databaseURL, mediaDirectoryURL: repository.mediaDirectoryURL)
    }

    func review(_ engine: LingroveNotebookEngine? = nil) throws -> NotebookBuiltInReviewSnapshot {
        try (engine ?? repository.engine).loadBuiltInNotebookReview(scope: repository.snapshot(), now: referenceNow)
    }

    func enroll() throws {
        let content = try review()
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: content.scope, selection: selection)
        _ = try repository.engine.enrollBuiltInNotebookSense(draft, input: draft.generatedContent,
            action: .init(content: content, selection: selection))
    }

    func rate(_ rating: ReviewRating, engine: LingroveNotebookEngine? = nil, offset: Double = 0) throws {
        let engine = engine ?? repository.engine
        let content = try review(engine)
        let card = try #require(content.review.groups[selection.senseID]?.cards.first)
        _ = try engine.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: rating,
            reviewedAtClient: formatIsoTimestamp(date: referenceNow.addingTimeInterval(-600 + offset)),
            reviewedTimeZone: "UTC"), card: card, action: .init(content: content, selection: selection))
    }

    func addEmptyWorkspace() throws -> String {
        let workspace = UUID().uuidString.lowercased()
        let now = formatIsoTimestamp(date: referenceNow)
        try repository.engine.core.execute(sql: """
            INSERT INTO workspaces(workspace_id,name,created_at,fsrs_client_updated_at,fsrs_last_modified_by_replica_id,fsrs_last_operation_id)
            VALUES(?,'Progress synthetic workspace',?,?,?,?)
            """, values: [.text(workspace), .text(now), .text(now), .text(UUID().uuidString), .text(UUID().uuidString)])
        _ = try repository.engine.loadLingroveNotebook(workspaceId: workspace)
        return workspace
    }

    /// The same eight boundaries are storage-tested by the portable suite. Native rendering
    /// prepares them through real enrollment/rating commands, then changes only fixture due
    /// timestamps (with matching millis) so every original donut wedge is visible for inspection.
    func populateForecastRanges() throws {
        let engine = repository.engine
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: referenceNow)
        let first = try #require(review().review.groups[selection.senseID]?.cards.first)
        try setFixtureDue(first, offset: 1, start: start, calendar: calendar)
        let offsets: [Int?] = [0, 8, 31, 91, 361, 721, nil]
        for offset in offsets {
            var content = try review()
            let draft = try LingroveNotebookCardMaterial.draft(snapshot: content.scope, selection: selection)
            let card = try engine.addBuiltInNotebookExercise(draft, input: draft.generatedContent,
                action: .init(content: content, selection: selection))
            if let offset {
                content = try review()
                _ = try engine.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
                    reviewedAtClient: formatIsoTimestamp(date: referenceNow.addingTimeInterval(-10)), reviewedTimeZone: "UTC"),
                    card: card, action: .init(content: content, selection: selection))
                try setFixtureDue(card, offset: offset, start: start, calendar: calendar)
            }
        }
    }

    private func setFixtureDue(_ card: Card, offset: Int, start: Date, calendar: Calendar) throws {
        let due = try #require(calendar.date(byAdding: .day, value: offset, to: start))
        try repository.engine.core.execute(sql: "UPDATE cards SET due_at=?,due_at_millis=? WHERE workspace_id=? AND card_id=?",
            values: [.text(formatIsoTimestamp(date: due)), .integer(Int64(due.timeIntervalSince1970 * 1_000)),
                .text(card.workspaceId), .text(card.cardId)])
    }

    func cleanUp() {
        try? repository.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}
