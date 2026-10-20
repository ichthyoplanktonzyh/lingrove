import AppKit
import Testing
@testable import Cotabby

/// Fake OS display retains only explicit fixtures. The production presenter still constructs real
/// source windows, so late attachments and repeated lookup test its actual ownership boundary.
@Suite(.serialized)
@MainActor
struct LearningSystemDictionaryPresenterTests {
    @Test(arguments: [false, true])
    func vocabularyControlLivesInsideTheNativePopupWithoutTakingFocus(flipped: Bool) async throws {
        let parent = window()
        defer { parent.close() }
        let button = button("posted", in: parent)
        let definition = NSPanel(contentRect: CGRect(x: 200, y: 250, width: 350, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        definition.isReleasedWhenClosed = false
        definition.contentView = DictionaryContentFixture(flipped: flipped)
        defer { definition.close() }
        let presenter = LearningSystemDictionaryPresenter { view, _, _ in
            view.window?.addChildWindow(definition, ordered: .above)
            definition.orderFrontRegardless()
        }
        defer { presenter.dismiss() }
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let capture = VocabularyCapture(expression: "posted", dictionaryForm: "post", language: .english, kind: .word)
        presenter.show("posted", from: button, vocabulary: store, capture: capture)
        for _ in 0..<5 { await Task.yield() }
        let content = try #require(definition.contentView)
        let accessory = try #require(content.subviews.first { $0.identifier == LearningSystemDictionaryPresenter.favoriteViewIdentifier })
        #expect(accessory.window === definition, "A separate accessory window is an outside click to the system dictionary")
        #expect(!accessory.isHiddenOrHasHiddenAncestor && !definition.canBecomeKey)
        #expect(definition.childWindows?.isEmpty != false)
        #expect(presenter.owns(accessory.window))
        #expect(content.bounds.contains(accessory.frame))
        #expect(presenter.vocabularyCapture == capture)
        let center = accessory.convert(NSPoint(x: accessory.bounds.midX, y: accessory.bounds.midY), to: content)
        #expect(content.hitTest(center)?.window === definition)
        let originalRight = content.bounds.maxX - accessory.frame.maxX
        let originalTop = flipped ? accessory.frame.minY - content.bounds.minY : content.bounds.maxY - accessory.frame.maxY
        definition.setContentSize(CGSize(width: 420, height: 260))
        #expect(content.bounds.maxX - accessory.frame.maxX == originalRight)
        let resizedTop = flipped ? accessory.frame.minY - content.bounds.minY : content.bounds.maxY - accessory.frame.maxY
        #expect(resizedTop == originalTop)
        await store.save(capture)
        #expect(definition.isVisible && presenter.vocabularyCapture == capture)
        presenter.dismiss()
        #expect(accessory.superview == nil)
        #expect(presenter.vocabularyCapture == nil)
    }

    @Test
    func inlineTextAnchorsUseTheSameNativePopupAndDismissalLifetime() throws {
        let parent = window()
        defer { parent.close() }
        let textView = NSTextView(frame: CGRect(x: 10, y: 20, width: 280, height: 60), textContainer: nil)
        textView.string = "I like you."
        parent.contentView?.addSubview(textView)
        let textBounds = CGRect(x: 12, y: 5, width: 25, height: 20)
        var source: NSWindow?
        var displayed = ""
        let presenter = LearningSystemDictionaryPresenter { view, text, _ in
            source = view.window
            displayed = text.string
        }
        defer { presenter.dismiss() }
        presenter.show("like", from: textView, textBounds: textBounds, font: .systemFont(ofSize: 16))
        let anchor = try #require(source)
        let expected = parent.convertToScreen(textView.convert(textBounds, to: nil))
        #expect(displayed == "like" && anchor.parent === parent)
        #expect(abs(anchor.frame.minX - expected.minX) <= 1)
        #expect(abs(anchor.frame.minY - expected.minY) <= 1)
        #expect(!anchor.canBecomeKey)
        presenter.dismiss()
        #expect(!anchor.isVisible && parent.isVisible)
    }
    @Test
    func lookupAnchorsToTheClickedTitleWithoutTakingKeyFocus() throws {
        let parent = window()
        defer { parent.close() }
        let button = button("학교", in: parent)
        var displayedText = ""
        var displayedBaseline = NSPoint.zero
        var source: NSWindow?
        let definition = popup()
        defer { definition.close() }
        let presenter = LearningSystemDictionaryPresenter { view, text, baseline in
            displayedText = text.string
            displayedBaseline = baseline
            source = view.window
            view.window?.addChildWindow(definition, ordered: .above)
            definition.orderFrontRegardless()
        }
        defer { presenter.dismiss() }
        presenter.show("학교", from: button)
        let anchor = try #require(source)
        let title = try #require(button.cell?.titleRect(forBounds: button.bounds))
        let expectedTitle = parent.convertToScreen(button.convert(title, to: nil))
        #expect(abs(anchor.frame.minX - expectedTitle.minX) <= 1)
        #expect(abs(anchor.frame.minY - expectedTitle.minY) <= 1)
        #expect(anchor.parent === parent)
        #expect(anchor.ignoresMouseEvents)
        #expect(!anchor.canBecomeKey)
        #expect(!anchor.isKeyWindow)
        #expect(displayedText == "학교")
        #expect(anchor.convertPoint(toScreen: displayedBaseline).x == expectedTitle.minX)
        #expect(displayedBaseline.y >= 0 && displayedBaseline.y <= anchor.frame.height)
        #expect(presenter.dismiss())
        #expect(parent.isVisible)
        #expect(!anchor.isVisible)
        #expect(!presenter.dismiss())
    }

    @Test
    func dismissedOldRequestsCannotShowTheirPopupDuringANewerLookup() async throws {
        let parent = window()
        defer { parent.close() }
        let button = button("can", in: parent)
        var anchors: [LearningDictionarySourcePanel] = []
        let presenter = LearningSystemDictionaryPresenter { view, _, _ in
            if let source = view.window as? LearningDictionarySourcePanel { anchors.append(source) }
        }
        defer { presenter.dismiss() }
        presenter.show("can", from: button)
        let old = try #require(anchors.first)
        button.title = "do"
        presenter.show("do", from: button)
        let current = try #require(anchors.last)
        #expect(old !== current)
        #expect(!old.allowsDictionaryWindows)
        #expect(current.allowsDictionaryWindows)
        let late = popup()
        let fresh = popup()
        defer { late.close(); fresh.close() }
        old.addChildWindow(late, ordered: .above)
        // Reproduce AppKit ordering front after the public attachment hook returns.
        late.orderFrontRegardless()
        current.addChildWindow(fresh, ordered: .above)
        fresh.orderFrontRegardless()
        for _ in 0..<5 { await Task.yield() }
        #expect(!late.isVisible)
        #expect(fresh.isVisible)
        #expect(current.isVisible)
        #expect(parent.isVisible)
        presenter.dismiss()
        #expect(!fresh.isVisible)
    }

    @Test
    func invalidOrHiddenWordControlsDoNotDispatchLookup() {
        let parent = window()
        defer { parent.close() }
        let button = button("can", in: parent)
        var calls = 0
        let presenter = LearningSystemDictionaryPresenter { _, _, _ in calls += 1 }
        defer { presenter.dismiss() }
        presenter.show("different", from: button)
        presenter.show("", from: button)
        button.isHidden = true
        presenter.show("can", from: button)
        button.isHidden = false
        parent.orderOut(nil)
        presenter.show("can", from: button)
        #expect(calls == 0)
    }

    @Test
    func aSystemDismissedLookupDoesNotConsumeAnExtraEscape() throws {
        let parent = window()
        defer { parent.close() }
        let button = button("can", in: parent)
        let definition = popup()
        defer { definition.close() }
        var source: NSWindow?
        let presenter = LearningSystemDictionaryPresenter { view, _, _ in
            source = view.window
            view.window?.addChildWindow(definition, ordered: .above)
            definition.orderFrontRegardless()
        }
        defer { presenter.dismiss() }
        presenter.show("can", from: button)
        definition.close()
        #expect(try #require(source).isVisible)
        #expect(!presenter.dismiss())
        #expect(source?.isVisible == false)
    }

    @Test
    func aReparentedSystemWindowIsLeftToItsNewLookupOwner() async {
        let old = LearningDictionarySourcePanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let current = LearningDictionarySourcePanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        old.isReleasedWhenClosed = false
        current.isReleasedWhenClosed = false
        current.allowsDictionaryWindows = true
        let shared = popup()
        defer { shared.close(); old.close(); current.close() }
        old.addChildWindow(shared, ordered: .above)
        current.addChildWindow(shared, ordered: .above)
        shared.orderFrontRegardless()
        for _ in 0..<5 { await Task.yield() }
        #expect(shared.parent === current)
        #expect(shared.isVisible)
    }

    private func window() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 100, y: 180, width: 320, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        return panel
    }

    private func button(_ title: String, in panel: NSPanel) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.frame = CGRect(x: 20, y: 20, width: 80, height: 24)
        panel.contentView?.addSubview(button)
        return button
    }

    private func popup() -> NSPanel {
        let popup = NSPanel(contentRect: CGRect(x: 100, y: 220, width: 220, height: 140),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        popup.isReleasedWhenClosed = false
        return popup
    }
}

/// Native popover hosts may use either coordinate orientation. The shared corner placement must
/// stay within the same content view when AppKit resizes it, without inspecting system subviews.
private final class DictionaryContentFixture: NSView {
    let flippedCoordinates: Bool
    init(flipped: Bool) {
        flippedCoordinates = flipped
        super.init(frame: CGRect(x: 0, y: 0, width: 350, height: 200))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { flippedCoordinates }
}
