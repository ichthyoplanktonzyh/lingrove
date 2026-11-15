import Combine
import Testing
@testable import Lingrove

/// Tests the contract used by the coordinator, in addition to the pure timestamp policy. Only
/// captures from the same field AND focus sequence can satisfy another consumer's input refresh.
@MainActor
struct PostInputFocusFreshnessTests {
    @Test func reusesOnlyTheSameIdentitysFreshPostInputCapture() {
        let context = LingroveTestFixtures.focusedInputSnapshot(focusChangeSequence: 3)
        let provider = FreshnessFocusProvider(context: context)
        provider.captureStartedUptimeNanoseconds = 101
        provider.millisecondsSinceLastCapture = 5
        provider.refreshAfterInput(since: 100, identity: context.identity, maxAgeMilliseconds: 30)
        #expect(provider.refreshCount == 0)
        provider.refreshAfterInput(since: 102, identity: context.identity, maxAgeMilliseconds: 30)
        #expect(provider.refreshCount == 1, "A read started before the key cannot satisfy it")
        let recycledElement = FocusedInputIdentity(elementIdentifier: context.elementIdentifier, focusChangeSequence: 4)
        provider.refreshAfterInput(since: 100, identity: recycledElement, maxAgeMilliseconds: 30)
        #expect(provider.refreshCount == 2)
        provider.millisecondsSinceLastCapture = 31
        provider.refreshAfterInput(since: 100, identity: context.identity, maxAgeMilliseconds: 30)
        #expect(provider.refreshCount == 3)
    }

    @Test func unknownTimingOrFocusRemainsConservativeAndExplicitRefreshIsUnconditional() {
        let context = LingroveTestFixtures.focusedInputSnapshot()
        let provider = FreshnessFocusProvider(context: context)
        provider.refreshAfterInput(since: 100, identity: context.identity, maxAgeMilliseconds: 30)
        #expect(provider.refreshCount == 1)
        provider.captureStartedUptimeNanoseconds = 101
        provider.millisecondsSinceLastCapture = 0
        provider.refreshAfterInput(since: 100, identity: nil, maxAgeMilliseconds: 30)
        #expect(provider.refreshCount == 2)
        provider.refreshNow()
        #expect(provider.refreshCount == 3, "Explicit insertion validation must always perform its read")
    }
}

/// One in-memory focus source owned by a test, with no AX or published UI state. Its empty
/// nonisolated deinit avoids the macOS actor-deinit back-deployment issue in app-hosted fixtures.
@MainActor
private final class FreshnessFocusProvider: SuggestionFocusProviding {
    var snapshot: FocusSnapshot
    var millisecondsSinceLastCapture: Int?
    var captureStartedUptimeNanoseconds: UInt64?
    var refreshCount = 0
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> { Empty().eraseToAnyPublisher() }
    init(context: FocusedInputSnapshot) {
        snapshot = FocusSnapshot(applicationName: context.applicationName, bundleIdentifier: context.bundleIdentifier,
            capability: .supported, context: context)
    }
    nonisolated deinit {}
    func refreshNow() { refreshCount += 1 }
}
