import AppKit
import Foundation
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// Real SQL-backed presentation in both inherited native appearances. These are rendering and
/// read-state checks; chart pointer/keyboard selection remains a separate external UI journey.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct NotebookProgressNativePresentationTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func nativeSummaryCalendarAndEightBuckets(_ appearance: NSAppearance.Name) async throws {
        let fixture = try ReviewNativePresentationFixture()
        defer { fixture.cleanUp() }
        try fixture.seedProgress()
        let model = fixture.progressModel()
        defer { model.setActive(false) }
        model.setActive(true)
        await model.waitForIdle()
        let content = try loaded(model)
        #expect(content.snapshot.totalReviews == 10)
        #expect(content.snapshot.schedule.buckets.map(\.count) == Array(repeating: 1, count: 8))
        try await capture(NotebookProgressDestination(model: model), name: "progress-summary-calendar-minimum",
            appearance: appearance, size: .init(width: 640, height: 740))
        try await capture(NotebookProgressReviewsSection(chartDays: content.chartDays,
            chartCalendar: content.snapshot.calendar, selectionResetKey: content.snapshot.scope.generation)
            .modifier(NotebookProgressCardModifier()).padding(24), name: "progress-ratings-minimum",
            appearance: appearance, size: .init(width: 640, height: 500))
        try await capture(NotebookProgressReviewScheduleSection(schedule: content.snapshot.schedule)
            .modifier(NotebookProgressCardModifier()).padding(24), name: "progress-eight-buckets-minimum",
            appearance: appearance, size: .init(width: 560, height: 720))
        try await capture(NotebookProgressReviewScheduleSection(schedule: content.snapshot.schedule)
            .modifier(NotebookProgressCardModifier()).padding(24), name: "progress-eight-buckets-wide",
            appearance: appearance, size: .init(width: 820, height: 420))
        model.setActive(false)
        if case .inactive = model.state { } else { Issue.record("A hidden Progress destination must suspend") }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func nativeEmptyLoadingFailureAndRetry(_ appearance: NSAppearance.Name) async throws {
        let fixture = try ReviewNativePresentationFixture()
        defer { fixture.cleanUp() }
        let model = fixture.progressModel(reader: ReviewProgressFailureOnceReader(io: .init(
            databaseURL: fixture.repository.databaseURL, mediaDirectoryURL: fixture.repository.mediaDirectoryURL)))
        defer { model.setActive(false) }
        let host = ReviewNativePresentationHost(NotebookProgressDestination(model: model),
            appearance: appearance, size: .init(width: 640, height: 650))
        defer { host.close() }
        try await host.settle()
        try host.capture("progress-loading")
        model.setActive(true)
        await model.waitForIdle()
        guard case .failed = model.state else { Issue.record("Expected explicit read failure"); return }
        try await host.settle()
        try host.capture("progress-error")
        model.reload()
        await model.waitForIdle()
        try await host.settle()
        #expect(try loaded(model).snapshot.totalReviews == 0)
        try host.capture("progress-empty")
    }

    private func capture(_ content: some View, name: String, appearance: NSAppearance.Name, size: CGSize) async throws {
        let host = ReviewNativePresentationHost(content.background(Color(nsColor: .windowBackgroundColor)),
            appearance: appearance, size: size)
        defer { host.close() }
        try await host.settle()
        try host.capture(name)
    }

    private func loaded(_ model: NotebookProgressModel) throws -> NotebookProgressContent {
        guard case let .loaded(content) = model.state else {
            Issue.record("Expected a real SQL-backed Progress snapshot")
            throw ReviewProgressPresentationError.unexpectedState
        }
        return content
    }
}

private enum ReviewProgressPresentationError: Error { case readFailure, unexpectedState }

/// One injected failure exercises error/retry presentation. Retry delegates to the production
/// readonly actor, preserving the fixture's exact scope and frozen civil-date inputs.
private actor ReviewProgressFailureOnceReader: NotebookProgressReading {
    private let io: NotebookProgressIO
    private var shouldFail = true
    init(io: NotebookProgressIO) { self.io = io }
    func load(scope: NotebookProgressScope, now: Date, calendar: Calendar) async throws -> NotebookProgressContent {
        if shouldFail { shouldFail = false; throw ReviewProgressPresentationError.readFailure }
        return try await io.load(scope: scope, now: now, calendar: calendar)
    }
}
