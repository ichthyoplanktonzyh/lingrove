import Testing
@testable import Lingrove

/// Advance only the activity clock, while the short real refresh timer drives the coordinator.
/// This pins idle admission, six-second privacy expiry and wake-up races without running Vision.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VisualContextIdleTests {
    @Test func pollingCannotRenewAnIdleSessionAndTypingRestartsCapture() async throws {
        let fixture = IdleVisualFixture()
        defer { fixture.close() }
        fixture.start()
        try await fixture.wait { fixture.coordinator.status == .ready }
        fixture.uptime = 10
        for _ in 0..<100 { fixture.start() }
        try await Task.sleep(for: .milliseconds(90))
        let reads = fixture.providerReads
        try await Task.sleep(for: .milliseconds(90))
        #expect(fixture.generator.count == 1 && fixture.providerReads == reads)
        #expect(fixture.coordinator.excerpt(for: .init(snapshot: fixture.live, generation: 1)) == nil)
        fixture.live = LingroveTestFixtures.focusedInputSnapshot(precedingText: "New typing", windowTitle: "First")
        fixture.coordinator.noteInputActivity(for: fixture.live)
        try await fixture.wait { fixture.generator.count == 2 && fixture.coordinator.status == .ready }
        #expect(fixture.generator.contexts.last?.precedingText == "New typing")
    }

    @Test func genuineInputExtendsActivityUntilItsOwnDeadline() async throws {
        let fixture = IdleVisualFixture()
        defer { fixture.close() }
        fixture.start()
        try await fixture.wait { fixture.coordinator.status == .ready }
        fixture.uptime = 9
        fixture.coordinator.noteInputActivity(for: fixture.live)
        try await fixture.wait { fixture.generator.count >= 2 }
        fixture.uptime = 18
        let previous = fixture.generator.count
        try await fixture.wait { fixture.generator.count > previous }
        fixture.uptime = 19
        try await Task.sleep(for: .milliseconds(90))
        let stopped = fixture.generator.count
        try await Task.sleep(for: .milliseconds(90))
        #expect(fixture.generator.count == stopped)
    }

    @Test func staleSecureAndUnpermittedFieldsCannotWakeAnIdleSession() async throws {
        let fixture = IdleVisualFixture()
        defer { fixture.close() }
        fixture.start()
        try await fixture.wait { fixture.coordinator.status == .ready }
        fixture.uptime = 11
        fixture.coordinator.noteInputActivity(for: LingroveTestFixtures.focusedInputSnapshot(focusChangeSequence: 2))
        fixture.coordinator.noteInputActivity(for: LingroveTestFixtures.focusedInputSnapshot(windowTitle: "Other chat"))
        fixture.coordinator.noteInputActivity(for: LingroveTestFixtures.focusedInputSnapshot(isSecure: true))
        fixture.permission = false
        fixture.coordinator.noteInputActivity(for: fixture.live)
        try await Task.sleep(for: .milliseconds(90))
        #expect(fixture.generator.count == 1)
    }

    @Test func inputDuringAnOldCaptureQueuesOneImmediateFreshCaptureAfterCompletion() async throws {
        let fixture = IdleVisualFixture()
        defer { fixture.close() }
        fixture.generator.holdFirst = true
        fixture.start()
        try await fixture.wait { fixture.generator.pending != nil }
        fixture.uptime = 11
        fixture.coordinator.noteInputActivity(for: fixture.live)
        fixture.generator.release()
        try await fixture.wait { fixture.generator.count == 2 && fixture.coordinator.status == .ready }
        #expect(fixture.coordinator.latestExcerpt == "Current project agenda and deadline")
    }
}

@MainActor
private final class IdleVisualFixture {
    var uptime = 0.0
    var permission = true
    var providerReads = 0
    var live = LingroveTestFixtures.focusedInputSnapshot(windowTitle: "First")
    let generator = IdleVisualGenerator()
    lazy var coordinator: VisualContextCoordinator = {
        let value = VisualContextCoordinator(screenshotContextGenerator: generator,
            screenRecordingPermissionProvider: { [weak self] in self?.permission ?? false },
            refreshIntervalNanoseconds: 30_000_000, now: { [weak self] in self?.uptime ?? 0 })
        value.refreshContextProvider = { [weak self] in
            guard let self else { return nil }
            providerReads += 1
            return live
        }
        return value
    }()
    func start() { coordinator.startSessionIfNeeded(for: live, configuration: .local) }
    func close() { coordinator.cancel(resetState: true); generator.release() }
    func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate(), "Visual activity state did not settle")
    }
}

@MainActor
private final class IdleVisualGenerator: ScreenshotContextGenerating {
    var contexts: [FocusedInputSnapshot] = []
    var count: Int { contexts.count }
    var holdFirst = false
    var pending: CheckedContinuation<Void, Never>?
    func generateContext(for context: FocusedInputSnapshot, configuration: VisualContextConfiguration?,
                         onStatusChange: (@MainActor @Sendable (VisualContextStatus) -> Void)?) async throws -> VisualContextExcerpt {
        contexts.append(context)
        if holdFirst && count == 1 { await withCheckedContinuation { pending = $0 } }
        return .init(text: "Current project agenda and deadline")
    }
    func release() { let waiting = pending; pending = nil; waiting?.resume() }
}
