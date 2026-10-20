import AppKit
import SwiftUI
import Testing
@testable import Cotabby

/// Exercise the real SwiftUI selector and its window hook, including the missing AppKit
/// parent relationship seen during transient popover delivery. No global input is synthesized.
@Suite(.serialized)
@MainActor
struct DictionarySourceInteractionTests {
    @Test func sourcePopoverWithoutAParentSurvivesLocalAndGlobalClicksAndRetiresWithItsCapture() async throws {
        var hit = 0, dismissals = 0
        let panel = LearningSentencePanel(dictionaryProvider: SourceInteractionDictionary(),
            observesMouseEvents: false, windowAtPoint: { _ in hit })
        defer { panel.hide() }
        func show(_ id: UUID) {
            panel.show(.init(id: id, source: "我喜欢你", translation: "I like you.", chunks: [],
                sourceLanguage: .chinese, targetLanguage: .english, caret: CGRect(x: 180, y: 220, width: 1, height: 18),
                isExpanded: false, isGenerating: false, message: "", previousTranslation: nil, shortcutLabel: ""),
                expand: {}, dismiss: { dismissals += 1; panel.hide() })
        }
        show(UUID())
        await waitUntil { self.translationView(in: panel)?.frame.height ?? 0 > 0 }
        let text = try #require(translationView(in: panel))
        let layout = try #require(text.layoutManager), container = try #require(text.textContainer)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 2, length: 4), actualCharacterRange: nil)
        let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
        text.handleClick(at: CGPoint(x: bounds.midX + text.textContainerOrigin.x,
                                     y: bounds.midY + text.textContainerOrigin.y), count: 2)
        await waitUntil { panel.dictionarySession.content != .loading }
        let detail = try #require(NSApp.windows.first { $0.isVisible && $0.title == "Expression Dictionary" && panel.owns($0) })
        try await Task.sleep(for: .milliseconds(80))
        let detailView = try #require(detail.contentView)
        // The trailing blank area of the header must open the same menu as its source text.
        let headerPoint = CGPoint(x: detailView.bounds.maxX - 44,
            y: detailView.isFlipped ? detailView.bounds.minY + 22 : detailView.bounds.maxY - 22)
        try click(detail, at: detailView.convert(headerPoint, to: nil))
        await waitUntil { self.popover(in: panel) != nil }
        let popup = try #require(popover(in: panel))
        defer { popup.close() }
        try capture(popup, name: "dictionary-source-menu")
        popup.parent?.removeChildWindow(popup)
        popup.orderFrontRegardless()
        #expect(popup.parent == nil && panel.owns(popup))
        hit = popup.windowNumber
        let point = CGPoint(x: popup.frame.midX, y: popup.frame.midY)
        panel.dismissForOutsideClick(in: popup)
        panel.dismissForGlobalClick(at: point)
        #expect(dismissals == 0 && panel.containsGlobalInteraction(at: point))
        let source = panel.dictionarySession.selectedSource == .bundled ? LearningDictionarySource.system : .bundled
        let index = try #require(panel.dictionarySession.availableSources.firstIndex(of: source))
        let probe = try #require(reader(in: popup.contentView))
        // The zero-size background marks the center of the actual 260pt menu viewport.
        // Its content has 14pt top padding, 44pt rows and 4pt spacing. Click in row whitespace.
        let center = probe.convert(CGPoint.zero, to: nil)
        let height = min(360, CGFloat(panel.dictionarySession.availableSources.count) * 54 + 28)
        let optionPoint = CGPoint(x: center.x + 80, y: center.y + height / 2 - 36 - CGFloat(index) * 48)
        try click(popup, at: optionPoint)
        await waitUntil { panel.dictionarySession.selectedSource == source && !popup.isVisible }
        try #require(panel.dictionarySession.selectedSource == source, "The actual menu option must change the source")
        #expect(panel.isVisible && detail.isVisible && dismissals == 0)
        try capture(detail, name: "dictionary-source-after-selection")
        // Reopening creates a new registration; replacing the document must revoke it even
        // if AppKit retains the detached window object after SwiftUI has dismissed its view.
        try click(detail, at: detailView.convert(headerPoint, to: nil))
        await waitUntil { self.popover(in: panel) != nil }
        let retired = try #require(popover(in: panel))
        retired.parent?.removeChildWindow(retired)
        hit = retired.windowNumber
        show(UUID())
        #expect(!panel.owns(retired))
        #expect(!panel.containsGlobalInteraction(at: point))
        panel.hide()
        #expect(!panel.owns(retired))
    }

    @Test(arguments: [CGFloat(0.08), 0.7, 0.96])
    func sourceOptionAcceptsItsWholeRow(_ fraction: CGFloat) async throws {
        var presses = 0
        let host = NSHostingView(rootView: DictionarySourceRow(title: "System", subtitle: "English", selected: false) {
            presses += 1
        }.frame(width: 240))
        let window = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 240, height: 44),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        let point = CGPoint(x: host.bounds.width * fraction, y: host.bounds.midY)
        try click(window, at: host.convert(point, to: nil))
        await waitUntil { presses == 1 }
        #expect(presses == 1, "Text, empty middle space and trailing padding must activate the same row")
    }

    private func click(_ window: NSWindow, at location: CGPoint) throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        // SwiftUI resolves the action on release. Deliver in gesture order, including inside
        // a popover; prequeuing mouse-up can make its presentation tracker consume it early.
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"],
              let view = window.contentView else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    private func popover(in panel: LearningSentencePanel) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && reader(in: $0.contentView) != nil && panel.owns($0) }
    }
    private func reader(in view: NSView?) -> LearningPopoverReadingView? {
        if let reader = view as? LearningPopoverReadingView { return reader }
        return view?.subviews.lazy.compactMap { reader(in: $0) }.first
    }
    private func translationView(in panel: LearningSentencePanel) -> LearningDictionaryTextView? {
        func find(_ view: NSView) -> LearningDictionaryTextView? {
            if let text = view as? LearningDictionaryTextView, text.string == "I like you." { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        return NSApp.windows.first { $0.isVisible && $0.frame == panel.visibleFrame }?.contentView.flatMap(find)
    }
}

private actor SourceInteractionDictionary: LearningDictionaryProviding {
    func lookup(_ query: String, language: LearningLanguage, expression: Bool, source: LearningDictionarySource,
                configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        .systemText("Fixture definition.")
    }
}
