import Foundation
import Testing
@testable import Lingrove

/// Transitions use private preferences and no inference services. Delayed work must never reveal
/// an outgoing page, including when the menu closes or Reduce Motion changes mid-transition.
@MainActor
struct MenuBarPresentationModelTests {
    @Test func latestSelectionWinsAndStaleMeasurementsCannotRevealIt() async throws {
        let fixture = try Fixture()
        let model = fixture.model, defaults = fixture.defaults, name = fixture.name
        defer { defaults.removePersistentDomain(forName: name) }
        model.setPresented(true)
        model.select(.learning)
        #expect(model.selectedTask == .learning && model.displayedTask == .completion && !model.pageVisible)
        model.didFit(.completion)
        #expect(!model.pageVisible)
        model.select(.completion)
        try await Task.sleep(for: .milliseconds(110))
        #expect(model.displayedTask == .completion && model.pageVisible)
        model.select(.learning)
        try await Task.sleep(for: .milliseconds(110))
        #expect(model.displayedTask == .learning && !model.pageVisible)
        model.didFit(.completion)
        #expect(!model.pageVisible)
        model.didFit(.learning)
        #expect(model.pageVisible)
        #expect(MenuBarPresentationModel(defaults: defaults).selectedTask == .learning)
    }

    @Test func closingCancelsTheFadeAndReopeningStartsWithTheLatestPage() async throws {
        let fixture = try Fixture()
        let model = fixture.model, defaults = fixture.defaults, name = fixture.name
        defer { defaults.removePersistentDomain(forName: name) }
        model.setPresented(true); model.select(.learning); model.setPresented(false)
        try await Task.sleep(for: .milliseconds(110))
        #expect(model.displayedTask == .learning && model.pageVisible)
        model.setPresented(true)
        #expect(model.displayedTask == model.selectedTask && model.pageVisible)
    }

    @Test func reduceMotionSettlesAnInFlightTransitionAndSubsequentSelectionsAreImmediate() async throws {
        let fixture = try Fixture()
        let model = fixture.model, defaults = fixture.defaults, name = fixture.name
        defer { defaults.removePersistentDomain(forName: name) }
        model.setPresented(true); model.select(.learning); model.setReduceMotion(true)
        #expect(model.displayedTask == .learning && model.pageVisible)
        model.select(.completion)
        #expect(model.displayedTask == .completion && model.pageVisible)
        try await Task.sleep(for: .milliseconds(110))
        #expect(model.displayedTask == .completion && model.pageVisible)
    }

    @MainActor
    private struct Fixture {
        let name = "MenuTransition-" + UUID().uuidString
        let defaults: UserDefaults
        let model: MenuBarPresentationModel
        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            model = MenuBarPresentationModel(defaults: defaults)
        }
    }
}
