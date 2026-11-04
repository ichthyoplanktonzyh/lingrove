import AppKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// Native render artifacts and exact-window commands protect the presentation boundary.
/// Pointer automation remains separate because this host's in-process SwiftUI AX tree is empty.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct BuiltInReviewNativePresentationTests {
    @Test func materialBaselineTracksEditsAndReversions() throws {
        let fixture = try ReviewNativePresentationFixture()
        defer { fixture.cleanUp() }
        var draft = try BuiltInReviewDraft(content: fixture.review(), selection: fixture.selection)
        let original = BuiltInReviewDraftPresentationSnapshot(draft)
        draft.front += " — edited"
        #expect(BuiltInReviewDraftPresentationSnapshot(draft) != original)
        draft.front = original.front
        #expect(BuiltInReviewDraftPresentationSnapshot(draft) == original)
        let example = try #require(draft.snapshot.document.entries.first?.senses.first?.examples.first?.id)
        draft.chooseExample(example)
        #expect(BuiltInReviewDraftPresentationSnapshot(draft) != original)
        #expect(try fixture.review().statistics.exercises == 0)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func nativeDestinationsAndKeyboardScope(_ appearance: NSAppearance.Name) async throws {
        let fixture = try ReviewNativePresentationFixture()
        defer { fixture.cleanUp() }
        fixture.session.open(selection: fixture.selection)
        await fixture.session.waitForIdle()
        let appAppearance = NSApp.appearance
        let host = ReviewNativePresentationHost(BuiltInReviewWindowView(session: fixture.session),
            appearance: appearance, size: .init(width: 640, height: 680))
        defer { host.close() }
        let keyboard = BuiltInReviewWindowController(session: fixture.session)
        keyboard.attachPresentation(to: host.window)
        keyboard.setPresentationActive(true)
        defer { keyboard.shutdown() }
        try await host.settle()
        try host.capture("review-sense-unenrolled")
        fixture.session.showAdding()
        try await host.settle()
        try host.capture("review-add-from-corpus")
        fixture.session.showDetail(fixture.selection)
        fixture.session.prepare(selection: fixture.selection, basedOn: try #require(fixture.session.content))
        try await host.settle()
        try host.capture("review-material-form", window: try #require(host.window.attachedSheet))
        let draft = try #require(fixture.session.draft)
        try await capture(LingroveReviewTextEditorScreen(field: .front, text: .constant(draft.front)),
            name: "review-material-editor", appearance: appearance, size: .init(width: 620, height: 520))
        fixture.session.draft = nil
        try await host.settle()
        #expect(try fixture.review().statistics.exercises == 0)
        try fixture.enroll()
        fixture.session.reload()
        await fixture.session.waitForIdle()
        fixture.session.showContent()
        try await host.settle()
        try host.capture("review-content-active")
        fixture.session.route = .overview
        try await host.settle()
        #expect(fixture.session.practice == nil)
        try host.capture("review-overview-minimum")
        fixture.session.start()
        try await host.settle()
        try host.capture("review-question-minimum")
        let digit = try key("3", in: host.window)
        let reveal = try key(" ", in: host.window)
        #expect(keyboard.keyboardAction(for: digit, isKeyWindow: true) == nil)
        #expect(keyboard.keyboardAction(for: reveal, isKeyWindow: false) == nil)
        keyboard.handle(try #require(keyboard.keyboardAction(for: reveal, isKeyWindow: true)))
        try await host.settle()
        #expect(keyboard.keyboardAction(for: digit, isKeyWindow: true) == .rate(.good))
        try host.capture("review-answer-minimum")
        let context = try #require(fixture.session.practice?.phase.context)
        var source: VocabularySelection?
        fixture.session.onOpenSource = { source = $0 }
        fixture.session.openSource(context)
        #expect(source == fixture.selection)
        fixture.session.edit(card: context.card, link: context.link,
            selection: context.group.selection, basedOn: try #require(fixture.session.content))
        try await host.settle()
        #expect(keyboard.keyboardAction(for: digit, isKeyWindow: true) == nil)
        fixture.session.draft = nil
        try await host.settle()
        keyboard.handle(try #require(keyboard.keyboardAction(for: digit, isKeyWindow: true)))
        await fixture.session.waitForIdle()
        try await host.settle()
        #expect(try fixture.review().statistics.ratingRecords == 1)
        try host.capture("review-finished-minimum")
        let content = try #require(fixture.session.content)
        try await capture(BuiltInReviewSenseChooser(content: content, onSelect: { _ in }),
            name: "review-sense-chooser", appearance: appearance, size: .init(width: 620, height: 560))
        try await capture(BuiltInReviewQueuePreviewView(content: content, currentCardID: nil),
            name: "review-queue", appearance: appearance, size: .init(width: 720, height: 580))
        try await capture(BuiltInReviewHistoryView(session: fixture.session, content: content),
            name: "review-history", appearance: appearance, size: .init(width: 620, height: 520))
        try await capture(LingroveReviewTextSelectionSheet(selection: .init(title: "Front", sourceText: context.card.frontText)),
            name: "review-text-selection", appearance: appearance, size: .init(width: 620, height: 460))
        fixture.session.undo(try #require(fixture.session.latestUndo))
        await fixture.session.waitForIdle()
        #expect(try fixture.review().statistics.undoneRatings == 1)
        fixture.session.endPractice()
        fixture.session.suspend()
        #expect(keyboard.keyboardAction(for: digit, isKeyWindow: true) == nil)
        fixture.session.resume()
        await fixture.session.waitForIdle()
        #expect(fixture.session.practice == nil && fixture.session.route == .overview)
        #expect(NSApp.appearance === appAppearance)
    }

    /// An external operator edits, cancels, keeps editing and explicitly discards one synthetic
    /// draft. Ready PID and .validation identity must be checked before attaching a UI tool.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINGROVE_UI_REVIEW_ONSCREEN"] != nil))
    func nativeDraftOnscreenCheckpoint() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LINGROVE_UI_REVIEW_ONSCREEN"]))
        let fixture = try ReviewNativePresentationFixture()
        defer { fixture.cleanUp() }
        fixture.session.open(selection: fixture.selection)
        await fixture.session.waitForIdle()
        let host = ReviewNativePresentationHost(BuiltInReviewWindowView(session: fixture.session),
            appearance: .aqua, size: .init(width: 900, height: 760))
        defer { host.close() }
        host.window.center()
        fixture.session.prepare(selection: fixture.selection, basedOn: try #require(fixture.session.content))
        try await host.settle()
        let sheet = try #require(host.window.attachedSheet)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let done = output.appendingPathComponent("done.json")
        try JSONSerialization.data(withJSONObject: [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "windowNumber": host.window.windowNumber, "sheetNumber": sheet.windowNumber,
            "database": fixture.repository.databaseURL.path, "done": done.path
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("ready.json"))
        for _ in 0..<1500 {
            if FileManager.default.fileExists(atPath: done.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(FileManager.default.fileExists(atPath: done.path), "The bounded private-host handoff must finish")
        #expect(fixture.session.draft == nil && host.window.attachedSheet == nil)
        let exercises = try fixture.review().statistics.exercises
        #expect(exercises == 0)
        try JSONSerialization.data(withJSONObject: ["draftClosed": fixture.session.draft == nil,
            "exercises": exercises, "userDataTouched": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("stored-result.json"))
    }

    private func capture(_ content: some View, name: String, appearance: NSAppearance.Name, size: CGSize) async throws {
        let host = ReviewNativePresentationHost(content, appearance: appearance, size: size)
        defer { host.close() }
        try await host.settle()
        try host.capture(name)
    }

    private func key(_ value: String, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value,
            isARepeat: false, keyCode: 0))
    }
}
