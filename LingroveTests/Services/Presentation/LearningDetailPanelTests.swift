import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Lingrove

/// These fixtures exercise dictionary geometry and the public window-family relationship;
/// no real dictionary, editor, or generation service participates.
@Suite(.serialized)
@MainActor
struct LearningDetailPanelTests {
    @Test(arguments: [false, true])
    func measuredHTMLLocksItsViewportBeforeSwitchingToStructuredDefinitions(_ long: Bool) async throws {
        let html = "<p>" + String(repeating: "A local dictionary article. ", count: long ? 80 : 1) + "</p>"
        let provider = LayoutDictionaryProbe(delayedBundled: false, html: html)
        let panel = LearningDetailPanel(provider: provider)
        defer { panel.hide() }
        panel.show(Self.unit(), documentID: UUID(), language: .english, placement: try placement())
        // Select before the initial task can publish a bundled result. HTML must establish
        // its own viewport through the real WebKit binding and geometry transactions.
        panel.dictionarySession.selectSource(.system)
        await waitUntil { self.webView(in: panel) != nil }
        let web = try #require(webView(in: panel))
        await waitUntil { !web.isLoading && web.estimatedProgress == 1 && (!long || abs(web.bounds.height - 120) > 1) }
        #expect(!web.isLoading && web.estimatedProgress == 1)
        try await Task.sleep(for: .milliseconds(100))
        let first = try #require(panel.visibleFrame)
        if !long { #expect(first.height < 340, "A short rich article should remain compact") }
        panel.dictionarySession.selectSource(.bundled)
        await waitUntil { if case .result(.entries) = panel.dictionarySession.content { return true }; return false }
        try await Task.sleep(for: .milliseconds(120))
        #expect(panel.visibleFrame == first)
        try capture(panel, name: long ? "dictionary-long-html-to-bundled" : "dictionary-short-html-to-bundled")
    }

    @Test func shortToLongSourceUsesTheSameWindowViewport() async throws {
        let provider = LayoutDictionaryProbe(delayedBundled: false)
        let panel = LearningDetailPanel(provider: provider)
        defer { panel.hide() }
        panel.show(Self.unit(), documentID: UUID(), language: .english, placement: try placement())
        await waitUntil { panel.dictionarySession.content != .loading }
        try await Task.sleep(for: .milliseconds(150))
        let first = try #require(panel.visibleFrame)
        panel.dictionarySession.selectSource(.system)
        await waitUntil { panel.dictionarySession.content == .result(.systemText(LayoutDictionaryProbe.longText)) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(panel.visibleFrame == first)
        try capture(panel, name: "dictionary-short-to-long")
    }

    @Test func restoringAMovedParentInvalidatesTheOldScreenPosition() throws {
        let panel = LearningDetailPanel()
        defer { panel.hide() }
        let original = try placement()
        panel.show(Self.unit(), documentID: UUID(), language: .english, placement: original)
        panel.updateParent(nil, caret: original.caret, reserved: nil, screen: original.screen)
        #expect(!panel.isVisible)
        let moved = original.parent.offsetBy(dx: original.screen.width - original.parent.width - 100, dy: -100)
        panel.updateParent(moved, caret: original.caret.offsetBy(dx: moved.minX - original.parent.minX, dy: -100),
            reserved: nil, screen: original.screen)
        let frame = try #require(panel.visibleFrame)
        let expected = try #require(LearningDetailPanelLayout.frame(parent: moved, anchorY: moved.maxY,
            size: CGSize(width: frame.width, height: 480), screen: original.screen,
            obstacles: [LearningDetailPanelLayout.protectedTextRect(original.caret.offsetBy(dx: moved.minX - original.parent.minX,
                dy: -100), screen: original.screen)]))
        #expect(frame.minX == expected.minX && frame.maxY == expected.maxY)
    }

    @Test func switchingSourcesRetainsFrameDuringLoadingAndShorterDefinitions() async throws {
        let provider = LayoutDictionaryProbe()
        let panel = LearningDetailPanel(provider: provider)
        defer { panel.hide() }
        let placement = try placement()
        panel.show(Self.unit(), documentID: UUID(), language: .english, placement: placement)
        panel.dictionarySession.selectSource(.system)
        await waitUntil { panel.dictionarySession.content == .result(.systemText(LayoutDictionaryProbe.longText)) }
        try await Task.sleep(for: .milliseconds(150))
        let first = try #require(panel.visibleFrame)
        try capture(panel, name: "dictionary-long-system")
        panel.dictionarySession.selectSource(.bundled)
        // The provider suspends independently of cancellation so this verifies the actual
        // intermediate loading paint as well as the final short entry and its attribution.
        try await Task.sleep(for: .milliseconds(40))
        #expect(panel.dictionarySession.content == .loading)
        #expect(panel.visibleFrame == first)
        try capture(panel, name: "dictionary-switch-loading")
        await provider.finish()
        await waitUntil { panel.dictionarySession.content != .loading }
        try await Task.sleep(for: .milliseconds(120))
        let last = try #require(panel.visibleFrame)
        try capture(panel, name: "dictionary-short-bundled")
        #expect(first == last, "A shorter source must use the existing viewport rather than moving the card")
        #expect(placement.screen.contains(last))
        #expect(!last.intersects(placement.parent.insetBy(dx: -8, dy: -8)))
        #expect(!last.intersects(placement.caret.insetBy(dx: -8, dy: -8)))
    }

    @Test
    func realDetailPopoverRemainsInternalAndIsRetiredWhenTheCardHides() async throws {
        let panel = LearningDetailPanel(provider: ExpressionDictionaryProbe())
        defer { panel.hide() }
        panel.show(Self.unit(), documentID: UUID(), language: .english, placement: try placement())
        let parent = try #require(NSApp.windows.first { panel.owns($0) && $0.parent == nil })
        var popup: NSWindow?
        let host = NSHostingView(rootView: FavoritePopoverWindowFixture { popup = $0 })
        host.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        parent.contentView?.addSubview(host)
        defer { popup?.close() }
        await waitUntil { popup?.isVisible == true }
        let window = try #require(popup)
        #expect(panel.owns(window), "The real SwiftUI popover belongs to the detail window")
        #expect(LearningWindowInteraction.contains(CGPoint(x: window.frame.midX, y: window.frame.midY),
            roots: panel.interactionWindows, hitWindowNumber: window.windowNumber))
        panel.show(Self.unit(identifier: 1), documentID: UUID(), language: .english, placement: try placement())
        await waitUntil { !window.isVisible }
        #expect(!window.isVisible, "Replacing the capture must retire the previous host's popover")
        #expect(panel.dictionarySession.selectedWord == nil)
        panel.hide()
        await waitUntil { !window.isVisible }
        #expect(!window.isVisible && parent.contentView == nil)
        panel.show(Self.unit(identifier: 2), documentID: UUID(), language: .english, placement: try placement())
        #expect(!window.isVisible && panel.dictionarySession.selectedWord == nil)
    }

    @Test
    func movingTheParentKeepsTheChildAttached() throws {
        let panel = LearningDetailPanel()
        defer { panel.hide() }
        let original = try placement()
        panel.show(Self.unit(), documentID: UUID(), language: .english, placement: original)
        let first = try #require(panel.visibleFrame)
        panel.updateParent(original.parent.offsetBy(dx: 0, dy: -80),
            caret: original.caret.offsetBy(dx: 0, dy: -80), reserved: nil, screen: original.screen)
        let moved = try #require(panel.visibleFrame)
        #expect(abs(moved.minY - first.minY + 80) < 1)
    }

    @Test
    func nativeLookupDescendantsArePartOfTheExplanationWindowFamily() throws {
        let panel = LearningDetailPanel()
        defer { panel.hide() }
        panel.show(Self.unit(), documentID: UUID(), language: .english, placement: try placement())
        let source = try #require(NSApp.windows.first { panel.owns($0) && $0.parent == nil })
        let anchor = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let popup = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        anchor.isReleasedWhenClosed = false
        popup.isReleasedWhenClosed = false
        defer { popup.close(); anchor.close() }
        source.addChildWindow(anchor, ordered: .above)
        anchor.addChildWindow(popup, ordered: .above)
        #expect(panel.owns(source))
        #expect(panel.owns(anchor))
        #expect(panel.owns(popup))
        #expect(!panel.owns(nil))
    }

    @Test
    func replacingOrClosingTheLookupClearsItsSession() throws {
        let panel = LearningDetailPanel()
        defer { panel.hide() }
        let first = UUID(), next = UUID()
        panel.show(Self.unit(), documentID: first, language: .english, placement: try placement())
        panel.show(Self.unit(identifier: 1), documentID: next, language: .english, placement: try placement())
        #expect(panel.dictionarySession.documentID == next)
        panel.hide()
        #expect(panel.dictionarySession.unit == nil && panel.dictionarySession.documentID == nil)
        #expect(!panel.isVisible)
    }

    @Test
    func expressionComponentLookupKeepsItsEntryAndRejectsReplacedDocumentControls() async throws {
        let panel = LearningDetailPanel(provider: ExpressionDictionaryProbe())
        defer { panel.hide() }
        let text = "look forward to"
        let unit = LearningUnit(id: 0, surface: text, query: text, kind: .expression,
            ranges: [.init(location: 0, length: text.utf16.count)],
            words: LearningUnitPolicy.words(in: text, language: .english))
        let id = UUID()
        let placement = try placement()
        panel.show(unit, documentID: id, language: .english, placement: placement)
        await waitUntil { panel.dictionarySession.content == .result(.notFound) && panel.isVisible }
        let source = try #require(NSApp.windows.first { panel.owns($0) && $0.parent == nil })
        let button = NSButton(title: "forward", target: nil, action: nil)
        button.frame = CGRect(x: 20, y: 20, width: 100, height: 24)
        source.contentView?.addSubview(button)
        panel.selectDictionaryTerm("forward", from: button, unit: unit, documentID: id)
        #expect(panel.dictionarySession.unit == unit && panel.dictionarySession.selectedWord?.text == "forward")
        #expect(panel.isVisible && panel.owns(source))
        #expect(panel.dismissDictionary())
        #expect(panel.isVisible && panel.dictionarySession.selectedWord == nil)
        // The phrase itself is not a component word, even when a legacy button supplies it.
        button.title = text
        panel.selectDictionaryTerm(text, from: button, unit: unit, documentID: id)
        #expect(panel.dictionarySession.selectedWord == nil)
        let nextID = UUID()
        panel.show(unit, documentID: nextID, language: .english, placement: placement)
        source.contentView?.addSubview(button)
        button.title = "forward"
        panel.selectDictionaryTerm("forward", from: button, unit: unit, documentID: id)
        #expect(panel.dictionarySession.selectedWord == nil, "The same text in a newer document must reject an old control")
        panel.selectDictionaryTerm("forward", from: button, unit: unit, documentID: nextID)
        #expect(panel.dictionarySession.selectedWord?.text == "forward")
        panel.hide()
        panel.selectDictionaryTerm("forward", from: button, unit: unit, documentID: nextID)
        #expect(panel.dictionarySession.unit == nil)
    }

    @Test
    func expressionEntryCarriesTheSameSentenceContext() throws {
        let panel = LearningDetailPanel(provider: ExpressionDictionaryProbe())
        defer { panel.hide() }
        let context = "I can do it if you give me enough time."
        panel.show(Self.unit(), documentID: UUID(), language: .english, placement: try placement(), speechContext: context)
        #expect(panel.dictionarySession.speechContext == context)
        panel.hide()
        #expect(panel.dictionarySession.speechContext == nil)
    }

    private static func unit(identifier: Int = 0) -> LearningUnit {
        let text = "can do it"
        return .init(id: identifier, surface: text, query: text, kind: .expression,
            ranges: [.init(location: 0, length: text.utf16.count)], words: LearningUnitPolicy.words(in: text, language: .english))
    }

    private func placement() throws -> LearningDetailPlacement {
        let screen = try #require(NSScreen.main?.visibleFrame)
        let parent = CGRect(x: screen.minX + 40, y: screen.midY, width: 480, height: 200)
        return .init(parent: parent, caret: CGRect(x: parent.minX, y: parent.minY - 30, width: 2, height: 20),
            reserved: nil, screen: screen, anchorY: parent.maxY)
    }

    private func capture(_ panel: LearningDetailPanel, name: String) throws {
        guard let directory = LingroveCompatibility.processEnvironment["LINGROVE_UI_SCREENSHOT_DIR"],
              let view = panel.interactionWindows.compactMap({ $0 }).first?.contentView else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    private func webView(in panel: LearningDetailPanel) -> WKWebView? {
        func find(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        return panel.interactionWindows.compactMap { $0?.contentView }.lazy.compactMap(find).first
    }
}

private actor LayoutDictionaryProbe: LearningDictionaryProviding {
    static let longText = String(repeating: "A long dictionary definition with several meanings. ", count: 50)
    let delayedBundled: Bool
    let html: String?
    init(delayedBundled: Bool = true, html: String? = nil) {
        self.delayedBundled = delayedBundled
        self.html = html
    }
    private var pending: [CheckedContinuation<LearningDictionaryResult, Never>] = []
    func lookup(_ query: String, language: LearningLanguage, expression: Bool, source: LearningDictionarySource,
                configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        if source == .system {
            if let html { return .article(.init(html: html, text: "A local dictionary article.", sourceName: "Fixture")) }
            return .systemText(Self.longText)
        }
        if !delayedBundled { return shortResult }
        return await withCheckedContinuation { pending.append($0) }
    }
    private var shortResult: LearningDictionaryResult {
        .entries([.init(id: "short", language: "en", headword: "can do it", forms: [],
            senses: [.init(partOfSpeech: "phrase", definitions: ["Be able to do something."], labels: [])], sourceURL: "")])
    }
    func finish() {
        let result = shortResult
        let continuations = pending
        pending = []
        for continuation in continuations { continuation.resume(returning: result) }
    }
}

private actor ExpressionDictionaryProbe: LearningDictionaryProviding {
    func lookup(_ query: String, language: LearningLanguage, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        .notFound
    }
}
