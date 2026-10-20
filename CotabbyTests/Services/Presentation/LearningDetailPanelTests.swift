import AppKit
import SwiftUI
import Testing
@testable import Cotabby

/// These fixtures exercise correspondence geometry and the public window-family relationship;
/// no real dictionary, editor, or generation service participates.
@Suite(.serialized)
@MainActor
struct LearningDetailPanelTests {
    @Test
    func realDetailPopoverRemainsInternalAndIsRetiredWhenTheCardHides() async throws {
        let panel = LearningDetailPanel(provider: ExpressionDictionaryProbe())
        defer { panel.hide() }
        panel.show(Self.chunk(), placement: try placement())
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
        panel.show(Self.chunk(identifier: 1), placement: try placement())
        await waitUntil { !window.isVisible }
        #expect(!window.isVisible, "Replacing the capture must retire the previous host's popover")
        #expect(panel.dictionarySession.selectedWord == nil)
        panel.hide()
        await waitUntil { !window.isVisible }
        #expect(!window.isVisible && parent.contentView == nil)
        panel.show(Self.chunk(identifier: 2), placement: try placement())
        #expect(!window.isVisible && panel.dictionarySession.selectedWord == nil)
    }

    @Test
    func movingTheParentKeepsTheChildAttached() throws {
        let panel = LearningDetailPanel()
        defer { panel.hide() }
        let original = try placement()
        panel.show(Self.chunk(), placement: original)
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
        panel.show(Self.chunk(), placement: try placement())
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
    func replacingOrClosingTheExplanationClearsItsSelection() throws {
        let panel = LearningDetailPanel()
        panel.show(Self.chunk(), placement: try placement())
        panel.show(Self.chunk(identifier: 1), placement: try placement())
        #expect(panel.state.chunk?.chunkID == 1)
        panel.hide()
        #expect(panel.state.chunk == nil)
        #expect(!panel.isVisible)
    }

    @Test
    func lookupRejectsStaleChunksAndReturnsBeforeClosingTheExpression() throws {
        let panel = LearningDetailPanel(provider: ExpressionDictionaryProbe())
        defer { panel.hide() }
        let original = Self.chunk()
        panel.show(original, placement: try placement())
        let source = try #require(NSApp.windows.first { panel.owns($0) && $0.parent == nil })
        let button = NSButton(title: "can", target: nil, action: nil)
        button.frame = CGRect(x: 20, y: 20, width: 80, height: 24)
        source.contentView?.addSubview(button)
        panel.selectWord("can", from: button, chunk: original)
        #expect(panel.dictionarySession.selectedWord?.text == "can")
        #expect(panel.dismissDictionary())
        #expect(panel.isVisible)
        #expect(panel.state.chunk == original)
        #expect(!panel.dismissDictionary())
        let next = Self.chunk(identifier: 1)
        panel.show(next, placement: try placement())
        source.contentView?.addSubview(button)
        panel.selectWord("can", from: button, chunk: original)
        button.title = "unlisted"
        panel.selectWord("unlisted", from: button, chunk: next)
        #expect(panel.dictionarySession.selectedWord == nil)
        panel.hide()
        button.title = "can"
        panel.selectWord("can", from: button, chunk: next)
        #expect(panel.dictionarySession.unit == nil)
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
        panel.show(unit, documentID: id, language: .english, correspondence: nil, placement: placement)
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
        panel.show(unit, documentID: nextID, language: .english, correspondence: nil, placement: placement)
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

    @Test(arguments: [false, true])
    func unitAndMeaningChunkEntriesCarryTheSameSentenceContext(meaningChunk: Bool) throws {
        let panel = LearningDetailPanel(provider: ExpressionDictionaryProbe())
        defer { panel.hide() }
        let chunk = Self.chunk()
        let context = "I can do it if you give me enough time."
        if meaningChunk {
            panel.show(chunk, placement: try placement(), speechContext: context)
        } else {
            let unit = LearningUnit(id: 0, surface: chunk.target, query: chunk.target, kind: .expression,
                ranges: [], words: LearningUnitPolicy.words(in: chunk.target, language: .english))
            panel.show(unit, documentID: chunk.documentID, language: .english,
                correspondence: nil, placement: try placement(), speechContext: context)
        }
        #expect(panel.dictionarySession.speechContext == context)
        panel.hide()
        #expect(panel.dictionarySession.speechContext == nil)
    }

    private static func chunk(identifier: Int = 0) -> LearningChunkDetail {
        .init(documentID: UUID(), chunkID: identifier, source: "能做到", target: "can do it",
            language: .english, words: ["can", "do", "it"])
    }

    private func placement() throws -> LearningDetailPlacement {
        let screen = try #require(NSScreen.main?.visibleFrame)
        let parent = CGRect(x: screen.minX + 40, y: screen.midY, width: 480, height: 200)
        return .init(parent: parent, caret: CGRect(x: parent.minX, y: parent.minY - 30, width: 2, height: 20),
            reserved: nil, screen: screen, anchorY: parent.maxY)
    }
}

private actor ExpressionDictionaryProbe: LearningDictionaryProviding {
    func lookup(_ query: String, language: LearningLanguage, expression: Bool, source: LearningDictionarySource) async throws -> LearningDictionaryResult {
        .notFound
    }
}
