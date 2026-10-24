import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// The reported regression was visible UI starvation. Hold the test-only OCR child while the
/// actual menu controller fades/resizes and the learning panel lays out a long expression.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OCRPresentationIsolationTests {
    @Test func hungOCRChildDoesNotBlockMenuTransitionsOrLongCardExpansion() async throws {
        let fixture = try OCRRuntimeFixture(timeout: 20)
        defer { fixture.close() }
        let recognition = Task { try await fixture.recognize(903) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while fixture.requests.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(fixture.requests == [903])

        let name = "OCRPresentation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MenuBarPresentationModel(defaults: defaults)
        let menu = MenuBarController(presentation: model, content: AnyView(OCRMenuFixture(model: model)),
                                     statusLabel: AnyView(Text("OCR test")), onPresent: {})
        defer { menu.shutdown() }
        menu.setVisible(true)
        // Status-item windows are attached asynchronously by the system. Wait for that
        // native setup before asking a transient popover to anchor to its button.
        try await Task.sleep(for: .milliseconds(220))
        menu.toggle()
        try await Task.sleep(for: .milliseconds(350))
        try #require(menu.isShown)
        model.select(.learning)
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.displayedTask == .learning && model.pageVisible)
        #expect(menu.contentSize == CGSize(width: 340, height: 520))

        let card = LearningSentencePanel(observesMouseEvents: false)
        defer { card.hide() }
        let id = UUID()
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let caret = CGRect(x: screen.minX + 100, y: screen.midY, width: 1, height: 18)
        func presentation(expanded: Bool) -> LearningSentencePresentation {
            LearningSentencePresentation(id: id,
                source: String(repeating: "Keep me informed about the progress. ", count: 30),
                translation: String(repeating: "Please let me know if there is anything else we should discuss. ", count: 30),
                sourceLanguage: .english, targetLanguage: .english, caret: caret, isExpanded: expanded,
                isGenerating: false, message: "", previousTranslation: nil, shortcutLabel: "", unitStage: .ready)
        }
        card.show(presentation(expanded: false), expand: {}, dismiss: {})
        try await Task.sleep(for: .milliseconds(350))
        let compact = try #require(card.visibleFrame)
        card.show(presentation(expanded: true), expand: {}, dismiss: {})
        try await Task.sleep(for: .milliseconds(350))
        let expanded = try #require(card.visibleFrame)
        #expect(expanded.height > compact.height && expanded.width >= compact.width)
        let window = try #require(NSApplication.shared.windows.first { $0.isVisible && $0.frame == expanded })
        let content = try #require(window.contentView)
        #expect(content.fittingSize.height <= expanded.height + 1, "The host must fit the card rather than clip its top controls")
        #expect(fixture.events.count("finished") == 0, "UI assertions must happen while OCR remains blocked")
        try fixture.release()
        _ = try await recognition.value
    }
}

private struct OCRMenuFixture: View {
    @ObservedObject var model: MenuBarPresentationModel
    var body: some View {
        Color.clear.frame(width: 340, height: model.displayedTask == .completion ? 260 : 520)
            .fixedSize()
            .background(GeometryReader { geometry in
                Color.clear.preference(key: OCRMenuMeasurement.self,
                    value: MenuBarContentMeasurement(page: model.displayedTask, size: geometry.size))
            })
            .onPreferenceChange(OCRMenuMeasurement.self) { if let measurement = $0 { model.onMeasure?(measurement) } }
    }
}

private struct OCRMenuMeasurement: PreferenceKey {
    static let defaultValue: MenuBarContentMeasurement? = nil
    static func reduce(value: inout MenuBarContentMeasurement?, nextValue: () -> MenuBarContentMeasurement?) {
        if let next = nextValue() { value = next }
    }
}
