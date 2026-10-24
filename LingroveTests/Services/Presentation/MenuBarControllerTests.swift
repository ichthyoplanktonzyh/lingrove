import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Exercises the native container with disposable pages and private preferences. Real controls
/// are tested separately; this fixture tests the single sizing owner, close and visibility paths.
@MainActor
@Suite(.serialized)
struct MenuBarControllerTests {
    @Test func popoverFitsBothDirectionsAndClosesWithoutLeavingATransparentPage() async throws {
        _ = NSApplication.shared
        let name = "NativeMenu-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MenuBarPresentationModel(defaults: defaults)
        let fixture = MenuBarContainerFixture(model: model)
        var refreshes = 0
        let controller = MenuBarController(presentation: model, content: AnyView(fixture),
            statusLabel: AnyView(Text("Fixture"))) { refreshes += 1 }
        defer { controller.shutdown() }
        controller.setVisible(true)
        await settle()
        controller.toggle()
        await settle()
        #expect(controller.isShown && controller.contentSize == CGSize(width: 340, height: 260))
        model.select(.learning)
        await settle()
        #expect(model.pageVisible && controller.contentSize == CGSize(width: 340, height: 520))
        model.select(.completion)
        await settle()
        #expect(model.pageVisible && controller.contentSize == CGSize(width: 340, height: 260))
        // A late outgoing measurement must not enlarge the new page.
        model.onMeasure?(.init(page: .learning, size: CGSize(width: 340, height: 700)))
        await settle()
        #expect(controller.contentSize.height == 260)
        model.select(.learning)
        controller.close()
        await waitForClose(controller)
        #expect(!controller.isShown && model.displayedTask == .learning && model.pageVisible)
        controller.toggle()
        await settle()
        #expect(controller.isShown && controller.contentSize.height == 520 && refreshes == 2)
        // A new click during native dismissal is queued until didClose, so an old delegate
        // callback cannot turn off layout or clear the new page's state after reopening.
        controller.close(); controller.toggle()
        try await Task.sleep(for: .milliseconds(700))
        #expect(controller.isShown && model.pageVisible && controller.contentSize.height == 520)
        controller.setVisible(false)
        await waitForClose(controller)
        #expect(!controller.isShown)
        controller.setVisible(true)
        await settle()
        controller.toggle()
        await settle()
        #expect(controller.isShown && model.pageVisible)
    }

    private func waitForClose(_ controller: MenuBarController) async {
        // AppKit owns animation duration; wait for the observable close instead of assuming
        // that it matches the 80ms SwiftUI page fade.
        for _ in 0..<30 {
            if !controller.isShown { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(220))
    }
}

private struct MenuBarContainerFixture: View {
    @ObservedObject var model: MenuBarPresentationModel
    var body: some View {
        Color.clear.frame(width: 340, height: model.displayedTask == .completion ? 260 : 520)
            .fixedSize()
            .background(GeometryReader { geometry in
                Color.clear.preference(key: MenuFixtureMeasurementKey.self,
                    value: MenuBarContentMeasurement(page: model.displayedTask, size: geometry.size))
            })
            .onPreferenceChange(MenuFixtureMeasurementKey.self) { measurement in
                if let measurement { model.onMeasure?(measurement) }
            }
    }
}

private struct MenuFixtureMeasurementKey: PreferenceKey {
    static let defaultValue: MenuBarContentMeasurement? = nil
    static func reduce(value: inout MenuBarContentMeasurement?, nextValue: () -> MenuBarContentMeasurement?) {
        if let next = nextValue() { value = next }
    }
}
