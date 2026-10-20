import AppKit
import SwiftUI
import Testing
@testable import Cotabby

@Suite(.serialized)
@MainActor
struct LearningSentencePanelTests {
    @Test
    func globalNativeLookupClickSurvivesButAnOverlappingForeignWindowDismisses() async throws {
        let popup = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 220, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        defer { popup.close() }
        let dictionary = LearningSystemDictionaryPresenter { view, _, _ in
            view.window?.addChildWindow(popup, ordered: .above)
            popup.orderFrontRegardless()
        }
        var hit = 0
        let panel = LearningSentencePanel(dictionary: dictionary, dictionaryProvider: PanelDictionaryProbe(),
                                          windowAtPoint: { _ in hit })
        defer { panel.hide() }
        var dismissed = false
        panel.show(.init(id: UUID(), source: "我喜欢你", translation: "I like you.", chunks: [],
            sourceLanguage: .chinese, targetLanguage: .english, caret: CGRect(x: 180, y: 220, width: 1, height: 18),
            isExpanded: false, isGenerating: false, message: "", previousTranslation: nil, shortcutLabel: "⌥T"),
            expand: {}, dismiss: { dismissed = true; panel.hide() })
        await waitUntil {
            guard let view = self.textView(in: panel) else { return false }
            return view.frame.width > 0 && view.frame.height > 0 && view.visibleRect.contains(view.bounds)
        }
        let view = try #require(textView(in: panel))
        let manager = try #require(view.layoutManager), container = try #require(view.textContainer)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: (view.string as NSString).range(of: "like"), actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        dictionary.show("like", from: view, textBounds: bounds,
                        font: .systemFont(ofSize: 14))
        #expect(popup.isVisible)
        let point = CGPoint(x: popup.frame.midX, y: popup.frame.midY)
        hit = popup.windowNumber
        panel.dismissForGlobalClick(at: point)
        #expect(!dismissed && panel.isVisible && popup.isVisible,
                "A native lookup event delivered globally must survive until its button action")
        hit = popup.windowNumber + 100_000
        panel.dismissForGlobalClick(at: point)
        #expect(dismissed && !panel.isVisible && !popup.isVisible)
    }

    @Test
    func nativePopoverWindowIsIncludedInPreviewClickBoundary() async throws {
        let panel = LearningSentencePanel(dictionaryProvider: PanelDictionaryProbe())
        defer { panel.hide() }
        var dismissed = false
        panel.show(.init(id: UUID(), source: "很高兴认识你。", translation: "Nice to meet you.", chunks: [],
            sourceLanguage: .chinese, targetLanguage: .english, caret: CGRect(x: 180, y: 220, width: 1, height: 18),
            isExpanded: false, isGenerating: false, message: "", previousTranslation: nil, shortcutLabel: "⌥T"),
            expand: {}, dismiss: { dismissed = true; panel.hide() })
        await waitUntil { self.textView(in: panel, matching: "Nice to meet you.")?.window != nil }
        let anchor = try #require(textView(in: panel, matching: "Nice to meet you."))
        let content = NSViewController()
        content.view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .semitransient
        popover.contentViewController = content
        defer { popover.close() }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        await waitUntil { popover.isShown && content.view.window != nil }
        let window = try #require(content.view.window)
        panel.dismissForOutsideClick(in: window)
        #expect(!dismissed, "The actual AppKit popover must remain inside its nonactivating preview's boundary")
        #expect(panel.isVisible)
    }

    @Test
    func swiftUIPopoverWindowIsIncludedInPreviewClickBoundary() async throws {
        let panel = LearningSentencePanel(dictionaryProvider: PanelDictionaryProbe())
        defer { panel.hide() }
        var dismissed = false
        panel.show(.init(id: UUID(), source: "很高兴认识你。", translation: "Nice to meet you.", chunks: [],
            sourceLanguage: .chinese, targetLanguage: .english, caret: CGRect(x: 180, y: 220, width: 1, height: 18),
            isExpanded: false, isGenerating: false, message: "", previousTranslation: nil, shortcutLabel: "⌥T"),
            expand: {}, dismiss: { dismissed = true; panel.hide() })
        await waitUntil { self.textView(in: panel, matching: "Nice to meet you.")?.window != nil }
        let parent = try #require(textView(in: panel, matching: "Nice to meet you.")?.window)
        var popup: NSWindow?
        let host = NSHostingView(rootView: FavoritePopoverWindowFixture { popup = $0 })
        host.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        parent.contentView?.addSubview(host)
        defer { host.removeFromSuperview(); popup?.close() }
        await waitUntil { popup?.isVisible == true }
        let window = try #require(popup)
        panel.dismissForOutsideClick(in: window)
        #expect(!dismissed, "SwiftUI's actual popover must survive the local mouse-down filter")
        #expect(panel.isVisible)
    }

    @Test
    func favoritePopoverMouseDownDoesNotDismissBeforeItsActionRuns() async throws {
        let panel = LearningSentencePanel(dictionaryProvider: PanelDictionaryProbe())
        defer { panel.hide() }
        var dismissals = 0
        panel.show(.init(id: UUID(), source: "很高兴认识你。", translation: "Nice to meet you.", chunks: [],
            sourceLanguage: .chinese, targetLanguage: .english, caret: CGRect(x: 180, y: 220, width: 1, height: 18),
            isExpanded: false, isGenerating: false, message: "", previousTranslation: nil, shortcutLabel: "⌥T"),
            expand: {}, dismiss: { dismissals += 1; panel.hide() })
        await waitUntil { self.textView(in: panel, matching: "Nice to meet you.")?.window != nil }
        let root = try #require(textView(in: panel, matching: "Nice to meet you.")?.window)
        let popup = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 200, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let nested = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let outside = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        for window in [popup, nested, outside] { window.isReleasedWhenClosed = false }
        defer { nested.close(); popup.close(); outside.close() }
        root.addChildWindow(popup, ordered: .above)
        popup.addChildWindow(nested, ordered: .above)
        for window in [root, popup, nested] {
            panel.dismissForOutsideClick(in: window)
            #expect(dismissals == 0)
            #expect(panel.isVisible, "Popover controls must survive mouse-down until their action can run")
        }
        panel.dismissForOutsideClick(in: outside)
        #expect(dismissals == 1)
        #expect(!panel.isVisible, "Unrelated app windows must still dismiss the preview")
    }

    @Test
    func resizedPreviewKeepsItsPaintedContentAboveTheCaret() async throws {
        let screen = try #require(NSScreen.main?.visibleFrame)
        let caret = CGRect(x: screen.midX - 160, y: screen.midY, width: 2, height: 18)
        let panel = LearningSentencePanel(dictionaryProvider: PanelDictionaryProbe())
        defer { panel.hide() }
        let id = UUID()
        for text in ["Nice to meet you.", String(repeating: "It is nice to meet you. ", count: 12), "Hello."] {
            panel.show(.init(id: id, source: "很高兴认识你。", translation: text, chunks: [],
                sourceLanguage: .chinese, targetLanguage: .english, caret: caret,
                isExpanded: false, isGenerating: false, message: "", previousTranslation: nil,
                shortcutLabel: "⌥T", canReplace: true, replacementShortcutLabel: "⌃⌥T"),
                expand: {}, dismiss: {}, replace: {})
            await waitUntil {
                guard let view = self.textView(in: panel, matching: text) else { return false }
                return view.frame.height > 0 && view.visibleRect.height > 0
            }
            // Hosting views can also resize their NSWindow after the controller sets its frame.
            // Verify the painted text after those transactions, not just the pure layout result.
            try await Task.sleep(for: .milliseconds(80))
            let frame = try #require(panel.visibleFrame)
            let view = try #require(textView(in: panel, matching: text))
            let window = try #require(view.window)
            let painted = window.convertToScreen(view.convert(view.visibleRect, to: nil))
            #expect(frame.minY >= caret.maxY + LearningSentencePanelLayout.gap)
            #expect(painted.minY >= caret.maxY + LearningSentencePanelLayout.gap)
            #expect(screen.contains(frame))
        }
    }

    @Test
    func partialAlignmentSelectionAndWholeExpressionLookupUseDifferentRanges() async throws {
        let provider = PanelDictionaryProbe(), panel = LearningSentencePanel(dictionaryProvider: provider)
        defer { panel.hide() }
        let id = UUID(), text = "I look forward to seeing you."
        let phrase = (text as NSString).range(of: "look forward to")
        let unit = LearningUnit(id: phrase.location, surface: "look forward to", query: "look forward to",
            kind: .expression, ranges: [phrase], words: LearningUnitPolicy.words(in: "look forward to", language: .english))
        // Artificial source fragments isolate selection/range behavior from model quality.
        let chunks = [LearningMeaningChunk(id: 0, sourceRanges: [.init(location: 0, length: 1)],
                                          targetRanges: [(text as NSString).range(of: "forward")]),
                      LearningMeaningChunk(id: 1, sourceRanges: [.init(location: 1, length: 1)],
                                          targetRanges: [(text as NSString).range(of: "to")])]
        func presentation(_ documentID: UUID) -> LearningSentencePresentation {
            .init(id: documentID, source: "甲乙", translation: text, chunks: chunks,
                sourceLanguage: .chinese, targetLanguage: .english,
                caret: CGRect(x: 180, y: 220, width: 1, height: 18), isExpanded: true, isGenerating: false,
                message: "", previousTranslation: nil, shortcutLabel: "⌥T", units: [unit], unitStage: .ready)
        }
        panel.show(presentation(id), expand: {}, dismiss: {})
        await waitUntil { self.textView(in: panel, matching: text)?.frame.height ?? 0 > 0 }
        let view = try #require(textView(in: panel, matching: text))
        let manager = try #require(view.layoutManager), container = try #require(view.textContainer)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: chunks[1].targetRanges[0], actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        let point = NSPoint(x: bounds.midX + view.textContainerOrigin.x, y: bounds.midY + view.textContainerOrigin.y)
        view.handleClick(at: point, count: 1)
        #expect(panel.detailState.chunk?.chunkID == 1 && panel.detailState.chunk?.target == "to")
        let oldInspect = view.inspect, oldLookup = try #require(view.lookupUnit)
        view.handleClick(at: point, count: 2)
        for _ in 0..<200 {
            if await provider.queries == ["look forward to"] { break }
            await Task.yield()
        }
        #expect(await provider.queries == ["look forward to"])
        #expect(panel.detailState.chunk?.chunkID == 1, "Whole-expression lookup must preserve the clicked color, not choose the first overlap")
        panel.show(presentation(UUID()), expand: {}, dismiss: {})
        oldInspect(1)
        oldLookup(.init(unit: unit, bounds: bounds, font: .systemFont(ofSize: 18)), view)
        #expect(panel.detailState.chunk == nil, "An old document's color callback must not select a new document")
        #expect(await provider.queries == ["look forward to"], "An old dictionary callback must not issue another query")
    }

    @Test(arguments: [false, true])
    func nativeWordLookupSurvivesAnalysisUpdatesAndClosesWithInputPreview(_ expanded: Bool) async throws {
        let provider = PanelDictionaryProbe()
        var displayed = ""
        var anchor: NSWindow?
        let popup = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 220, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        popup.isReleasedWhenClosed = false
        defer { popup.close() }
        let dictionary = LearningSystemDictionaryPresenter { view, text, _ in
            displayed = text.string
            anchor = view.window
            view.window?.addChildWindow(popup, ordered: .above)
            popup.orderFrontRegardless()
        }
        let panel = LearningSentencePanel(dictionary: dictionary, dictionaryProvider: provider)
        defer { panel.hide() }
        let id = UUID()
        func presentation(chunks: [LearningMeaningChunk]) -> LearningSentencePresentation {
            .init(id: id, source: "我喜欢你", translation: "I like you.", chunks: chunks,
                sourceLanguage: .chinese, targetLanguage: .english,
                caret: CGRect(x: 180, y: 220, width: 1, height: 18), isExpanded: expanded, isGenerating: true,
                message: "正在准备语块对应…", previousTranslation: nil, shortcutLabel: "⌥T")
        }
        panel.show(presentation(chunks: []), expand: {}, dismiss: {})
        // SwiftUI assigns width before the fitted height/window transaction finishes. A real
        // click can only target painted content; wait for that same geometry in this fixture.
        await waitUntil {
            guard let view = self.textView(in: panel) else { return false }
            return view.frame.width > 0 && view.frame.height > 0 && view.visibleRect.contains(view.bounds)
        }
        let view = try #require(textView(in: panel))
        let manager = try #require(view.layoutManager), container = try #require(view.textContainer)
        manager.ensureLayout(for: container)
        let range = (view.string as NSString).range(of: "like")
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        let originalLookup = try #require(view.lookupUnit)
        var clickedUnit: LearningUnit?
        view.lookupUnit = { anchor, view in clickedUnit = anchor.unit; originalLookup(anchor, view) }
        view.handleClick(at: NSPoint(x: bounds.midX + view.textContainerOrigin.x,
            y: bounds.midY + view.textContainerOrigin.y), count: 2)
        #expect(clickedUnit == .word(.init(text: "like", range: range)))
        #expect(displayed == "like", "A word click must dispatch to native dictionary presentation")
        #expect(await provider.calls == 0, "Word lookup must bypass the flattened Dictionary Services provider")
        let source = try #require(anchor)
        #expect(source.isVisible)
        panel.show(presentation(chunks: [.init(id: 0, sourceRanges: [.init(location: 1, length: 2)],
            targetRanges: [.init(location: 2, length: 4)])]), expand: {}, dismiss: {})
        #expect(source.isVisible, "Background analysis must not close the fixed translation's word lookup")
        if expanded {
            await waitUntil { self.textView(in: panel)?.chunks.count == 1 }
            let updated = try #require(textView(in: panel))
            updated.handleClick(at: NSPoint(x: bounds.midX + updated.textContainerOrigin.x,
                y: bounds.midY + updated.textContainerOrigin.y), count: 1)
            #expect(panel.detailState.chunk?.chunkID == 0)
            updated.handleClick(at: NSPoint(x: bounds.midX + updated.textContainerOrigin.x,
                y: bounds.midY + updated.textContainerOrigin.y), count: 2)
            #expect(panel.detailState.chunk?.chunkID == 0, "Native word lookup must keep the selected meaning relation")
        }
        panel.hide()
        #expect(!source.isVisible)
        #expect(!popup.isVisible)
        #expect(panel.detailState.chunk == nil)
    }

    private func textView(in panel: LearningSentencePanel, matching text: String = "I like you.") -> LearningDictionaryTextView? {
        NSApp.windows.first {
            // AppKit can retain a dismissed popover's hidden parent for a later run-loop turn.
            // A frame/title match must not select that earlier fixture's emptied hosting view.
            $0.isVisible && $0.frame == panel.visibleFrame && $0.title == String(localized: "Expression Learning", table: "Learning")
        }
            .flatMap { $0.contentView }.flatMap { findTextView($0, matching: text) }
    }

    private func findTextView(_ view: NSView, matching text: String) -> LearningDictionaryTextView? {
        if let textView = view as? LearningDictionaryTextView, textView.string == text { return textView }
        return view.subviews.lazy.compactMap { findTextView($0, matching: text) }.first
    }
}

private actor PanelDictionaryProbe: LearningDictionaryProviding {
    private(set) var calls = 0
    private(set) var queries: [String] = []
    func lookup(_ query: String, language: LearningLanguage, expression: Bool) async throws -> LearningDictionaryResult {
        calls += 1
        queries.append(query)
        return .systemEntry
    }
}

/// A real SwiftUI popover exercises the platform bridge separately from an explicitly attached
/// child NSPanel. The probe observes its actual window rather than assuming an AppKit hierarchy.
private struct FavoritePopoverWindowFixture: View {
    let windowReady: (NSWindow) -> Void
    @State private var presented = false

    var body: some View {
        Color.clear.frame(width: 20, height: 20)
            .popover(isPresented: $presented) {
                Text("Favorite actions").padding(14)
                    .background(FavoritePopoverWindowProbe(windowReady: windowReady))
            }
            .onAppear { presented = true }
    }
}

private struct FavoritePopoverWindowProbe: NSViewRepresentable {
    let windowReady: (NSWindow) -> Void
    func makeNSView(context: Context) -> FavoritePopoverProbeView {
        let view = FavoritePopoverProbeView()
        view.windowReady = windowReady
        return view
    }
    func updateNSView(_ view: FavoritePopoverProbeView, context: Context) {}
}

private final class FavoritePopoverProbeView: NSView {
    var windowReady: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { windowReady?(window) }
    }
}
