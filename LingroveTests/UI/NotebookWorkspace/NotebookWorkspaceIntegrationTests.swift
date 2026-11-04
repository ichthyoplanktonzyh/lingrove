import AppKit
import Combine
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// These short native/storage checks protect the workspace boundary. The unchanged corpus and
/// extracted review views still own their own controls; tests verify their actual shared owners,
/// retained hosting graphs, sheet protection and committed SQLite results.
@Suite(.serialized)
@MainActor
struct NotebookWorkspaceIntegrationTests {
    @Test("Closing Settings revokes the sidebar's queued pane request")
    func settingsCloseRevokesQueuedSelection() async throws {
        let fixture = try NotebookWorkspaceFixture()
        do {
            fixture.window.onShowSettings?()
            let settings = try workspaceRequire(fixture.settingsWindow)
            let coordinator = try workspaceRequire(fixture.settings)
            settings.setFrameOrigin(.init(x: -3000, y: -3000))
            // Complete first appearance/restored-pane delivery before isolating the queued
            // sidebar request. Otherwise this test also races the private host's AppStorage.
            try await Task.sleep(for: .milliseconds(200))
            coordinator.navigation.open(.home)
            coordinator.navigation.request(.appearance)
            settings.close()
            try await Task.sleep(for: .milliseconds(30))
            workspaceExpect(coordinator.navigation.selection == .home)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    @Test("Sidebar selection defers review suspension and expires on Close or an explicit source link")
    func deferredSidebarLifecycle() async throws {
        let fixture = try NotebookWorkspaceFixture(usesRealProgress: true)
        do {
            let selection = try await fixture.seed()
            fixture.review.show(selection: selection)
            let window = try workspaceRequire(fixture.window.window)
            window.setFrameOrigin(.init(x: -3000, y: -3000))
            await fixture.review.session.waitForIdle()
            var isWritingBinding = true
            var reentrantPublications = 0
            let subscription = fixture.review.session.objectWillChange.sink {
                if isWritingBinding { reentrantPublications += 1 }
            }
            fixture.window.navigation.request(.progress)
            workspaceExpect(fixture.window.navigation.destination == .review)
            workspaceExpect(reentrantPublications == 0)
            isWritingBinding = false
            try await workspaceEventually { fixture.window.navigation.destination == .progress }
            workspaceExpect(window.toolbar?.items.isEmpty == true)
            try await captureWorkspace(window, name: "deferred-sidebar-progress")
            subscription.cancel()

            fixture.window.navigation.request(.review)
            fixture.window.show(selectedID: selection.entryID, senseID: selection.senseID)
            try await captureWorkspace(window, name: "deferred-sidebar-source")
            workspaceExpect(fixture.window.navigation.destination == .corpus)
            workspaceExpect(fixture.window.corpusHost?.rootView.selectedSenseID == selection.senseID)

            fixture.window.navigation.request(.progress)
            fixture.window.close()
            fixture.window.show()
            try await captureWorkspace(window, name: "deferred-sidebar-reopened")
            workspaceExpect(fixture.window.navigation.destination == .corpus)
            workspaceExpect(fixture.progress.visibility == [true, false])
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    @Test("Switching destinations retains the entire corpus root and scopes Progress visibility")
    func retainedCorpusAndVisibility() async throws {
        let fixture = try NotebookWorkspaceFixture()
        do {
            let selection = try await fixture.seed()
            fixture.window.show(selectedID: selection.entryID, senseID: selection.senseID)
            let window = try workspaceRequire(fixture.window.window)
            window.setFrameOrigin(.init(x: -3000, y: -3000))
            let original = try workspaceRequire(fixture.window.corpusHost)
            try await workspaceEventually { original.rootView.learning.senseID == selection.senseID }
            workspaceExpect(window.toolbar?.items.isEmpty == false, "The complete original corpus toolbar remains mounted")
            let appearance = original.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            let scope = try fixture.repository.snapshot()
            fixture.window.navigate(to: .review)
            await fixture.review.session.waitForIdle()
            workspaceExpect(window.title == NotebookWorkspaceCopy.title(.review))
            workspaceExpect(window.contentViewController?.view.appearance == nil,
                "Workspace navigation keeps the split host's inherited appearance")
            workspaceExpect(window.toolbar?.items.isEmpty == true, "Hidden corpus editing actions must leave the window toolbar")
            workspaceExpect(try fixture.repository.engine.loadActiveCardCount(workspaceId: scope.workspaceId) == 0,
                "Entering review is not enrollment")
            fixture.window.navigate(to: .progress)
            workspaceExpect(window.title == NotebookWorkspaceCopy.title(.progress))
            workspaceExpect(window.toolbar?.items.isEmpty == true, "Progress must not retain hidden corpus actions")
            workspaceExpect(fixture.progress.visibility == [true])
            fixture.window.navigate(to: .corpus)
            workspaceExpect(window.title == NotebookWorkspaceCopy.title(.corpus))
            workspaceExpect(fixture.progress.visibility == [true, false])
            workspaceExpect(fixture.window.corpusHost === original)
            workspaceExpect(original.rootView.learning.senseID == selection.senseID)
            workspaceExpect(original.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
            window.setContentSize(.init(width: 1000, height: 620))
            try await captureWorkspace(window, name: "corpus-minimum")
            workspaceExpect(original.view.bounds.width >= 760)
            workspaceExpect(window.toolbar?.items.isEmpty == false, "Returning to corpus restores its original toolbar")
            fixture.window.onShowSettings?()
            let settings = try workspaceRequire(fixture.settingsWindow)
            fixture.window.onShowAccount?()
            workspaceExpect(fixture.settingsWindow === settings, "Both footer actions use the existing settings window")
            settings.setFrameOrigin(.init(x: -3000, y: -3000))
            try await captureWorkspace(settings, name: "settings-account")
            fixture.window.navigate(to: .progress)
            fixture.window.close()
            workspaceExpect(fixture.progress.visibility.last == false)
            // The corpus owner survives window Close and accepts a normal durable edit.
            _ = try await fixture.seed("anchorage")
            workspaceExpect(try fixture.repository.snapshot().document.collectedEntries.count == 2)
            fixture.window.show()
            workspaceExpect(fixture.window.corpusHost === original)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    @Test("An unsaved review sheet blocks navigation and close; a source deep link waits for Cancel")
    func draftAndDeepLinkLifecycle() async throws {
        let fixture = try NotebookWorkspaceFixture()
        do {
            let source = try await fixture.seed()
            let other = try await fixture.seed("anchorage")
            fixture.review.show(selection: source)
            let window = try workspaceRequire(fixture.window.window)
            window.setFrameOrigin(.init(x: -3000, y: -3000))
            await fixture.review.session.waitForIdle()
            let content = try workspaceRequire(fixture.review.session.content)
            fixture.review.session.prepare(selection: source, basedOn: content)
            let draftID = try workspaceRequire(fixture.review.session.draft).id
            fixture.review.session.draft?.front = "An unsaved review draft"
            try await workspaceEventually { window.attachedSheet != nil }
            fixture.window.navigate(to: .corpus)
            fixture.window.show(selectedID: other.entryID, senseID: other.senseID)
            workspaceExpect(fixture.window.navigation.destination == .review)
            workspaceExpect(!fixture.window.windowShouldClose(window))
            workspaceExpect(fixture.review.session.draft?.id == draftID)
            workspaceExpect(fixture.review.session.draft?.front == "An unsaved review draft")
            try await captureWorkspace(window, name: "review-draft-protected")
            // Cancel belongs to the sheet. Only after its binding and native lifetime end may
            // the pending source request replace corpus selection; no preparation was written.
            fixture.review.session.draft = nil
            try await workspaceEventually { window.attachedSheet == nil && fixture.window.navigation.destination == .corpus }
            workspaceExpect(fixture.window.corpusHost?.rootView.selectedID == other.entryID)
            workspaceExpect(fixture.window.corpusHost?.rootView.selectedSenseID == other.senseID)
            workspaceExpect(try fixture.repository.engine.loadActiveCardCount(workspaceId: content.scope.workspaceId) == 0)
            // A corpus-owned editor sheet receives the same protection, without modifying the
            // read-only original page. The text is still present when its owner ends the sheet.
            let editor = NSTextView(frame: .init(x: 0, y: 0, width: 400, height: 220))
            editor.string = "Unsaved corpus editor text"
            let sheet = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            sheet.contentView = editor
            window.beginSheet(sheet, completionHandler: nil)
            fixture.review.show(selection: source)
            workspaceExpect(fixture.window.navigation.destination == .corpus && window.attachedSheet === sheet)
            workspaceExpect(!fixture.window.windowShouldClose(window) && editor.string == "Unsaved corpus editor text")
            window.endSheet(sheet)
            try await workspaceEventually { fixture.window.navigation.destination == .review }
            await fixture.review.session.waitForIdle()
            workspaceExpect(fixture.review.session.route == .sense(source))
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    @Test("A hidden review pauses IO and speech, while admitted rating and undo still drain on Close/Quit")
    func hiddenReviewAndAcceptedWrites() async throws {
        let fixture = try NotebookWorkspaceFixture()
        do {
            let selection = try await fixture.seed()
            fixture.review.show(selection: selection)
            await fixture.review.session.waitForIdle()
            let session = fixture.review.session
            let initial = try workspaceRequire(session.content)
            session.enrollDefault(selection: selection, basedOn: initial)
            await session.waitForIdle()
            session.start()
            session.reveal()
            session.rate(.good)
            try workspaceRequire(session.isMutating)
            fixture.window.navigate(to: .corpus)
            await session.waitForIdle()
            let scope = try fixture.repository.snapshot()
            workspaceExpect(try fixture.repository.engine.loadReviewEvents(workspaceId: scope.workspaceId).count == 1)
            workspaceExpect(!session.isRefreshing && !session.isMutating)
            let hiddenContent = session.content
            fixture.repository.publishChange()
            workspaceExpect(session.content?.scope == hiddenContent?.scope && !session.isRefreshing,
                "A hidden destination does not start a read for a repository notification")
            fixture.window.navigate(to: .review)
            await session.waitForIdle()
            let rated = try workspaceRequire(session.content)
            workspaceExpect(rated.statistics.ratingRecords == 1 && rated.queue.isEmpty)
            let undo = try workspaceRequire(session.latestUndo)
            session.undo(undo)
            try workspaceRequire(session.isMutating)
            fixture.window.close()
            // Quit's drain still owns the task even though ordinary Close already hid its UI.
            session.prepareForShutdown()
            await session.shutdownAfterDraining()
            let after = try fixture.repository.engine.loadBuiltInNotebookReview(scope: fixture.repository.snapshot(), now: Date())
            workspaceExpect(after.statistics.ratingRecords == 1 && after.statistics.undoneRatings == 1)
            workspaceExpect(after.queue.first?.reps == 0 && session.content == nil)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    @Test("The one embedded key handler admits only its exact visible review window and practice phase")
    func embeddedKeyboardFences() async throws {
        let fixture = try NotebookWorkspaceFixture()
        let keyboard = BuiltInReviewWindowController(session: fixture.review.session)
        let host = NSWindow(contentRect: .init(x: -3000, y: -3000, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        do {
            let selection = try await fixture.seed()
            let session = fixture.review.session
            session.open(selection: selection)
            await session.waitForIdle()
            session.enrollDefault(selection: selection, basedOn: try workspaceRequire(session.content))
            await session.waitForIdle()
            session.start()
            keyboard.attachPresentation(to: host)
            keyboard.setPresentationActive(true)
            let space = try key(" ", window: host)
            let digit = try key("3", window: host)
            workspaceExpect(keyboard.keyboardAction(for: space, isKeyWindow: true) == .reveal)
            workspaceExpect(keyboard.keyboardAction(for: digit, isKeyWindow: true) == nil)
            session.reveal()
            workspaceExpect(keyboard.keyboardAction(for: digit, isKeyWindow: true) == .rate(.good))
            workspaceExpect(keyboard.keyboardAction(for: digit, isKeyWindow: false) == nil)
            let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            workspaceExpect(keyboard.keyboardAction(for: try key("3", window: other), isKeyWindow: true) == nil)
            other.close()
            for value in ["\t", "x"] {
                workspaceExpect(keyboard.keyboardAction(for: try key(value, window: host), isKeyWindow: true) == nil)
            }
            let editor = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 80))
            host.contentView = editor
            try workspaceRequire(host.makeFirstResponder(editor))
            workspaceExpect(keyboard.keyboardAction(for: digit, isKeyWindow: true) == nil)
            workspaceExpect(keyboard.keyboardAction(for: try key("z", window: host, modifiers: .command), isKeyWindow: true) == nil)
            host.makeFirstResponder(nil)
            session.prepare(selection: selection, basedOn: try workspaceRequire(session.content))
            workspaceExpect(keyboard.keyboardAction(for: digit, isKeyWindow: true) == nil)
            session.draft = nil
            keyboard.setPresentationActive(false) // Corpus/progress is now the visible destination.
            workspaceExpect(keyboard.keyboardAction(for: digit, isKeyWindow: true) == nil)
            keyboard.shutdown()
            host.close()
            await fixture.cleanUp()
        } catch {
            keyboard.shutdown()
            host.close()
            await fixture.cleanUp()
            throw error
        }
    }

    @Test("Leaving during the read after a committed rating preserves and advances the same practice")
    func navigationDuringOwnRefresh() async throws {
        let fixture = try NotebookWorkspaceFixture()
        do {
            let first = try await fixture.seed()
            let second = try await fixture.seed("anchorage")
            fixture.review.show()
            let session = fixture.review.session
            await session.waitForIdle()
            session.enrollDefault(selection: first, basedOn: try workspaceRequire(session.content))
            await session.waitForIdle()
            session.enrollDefault(selection: second, basedOn: try workspaceRequire(session.content))
            await session.waitForIdle()
            session.start()
            let originalCardID = try workspaceRequire(session.practice?.phase.context).card.cardId
            session.reveal()
            var needsInterruption = true
            var navigationTask: Task<Void, Never>?
            let subscription = session.$isRefreshing.sink { refreshing in
                guard refreshing, needsInterruption, !session.isMutating else { return }
                needsInterruption = false
                // A MainActor task runs after reload finishes its synchronous setup, before
                // its actor read publishes. This deterministically cancels the post-write read.
                navigationTask = Task { @MainActor in
                    fixture.window.navigate(to: .corpus)
                    fixture.window.navigate(to: .review)
                }
            }
            session.rate(.good)
            await session.waitForIdle()
            await navigationTask?.value
            await session.waitForIdle()
            subscription.cancel()
            workspaceExpect(!needsInterruption)
            workspaceExpect(session.route == .practice && session.practice?.answered == 1)
            let next = try workspaceRequire(session.practice?.phase.context)
            workspaceExpect(next.card.cardId != originalCardID)
            workspaceExpect(session.content?.statistics.ratingRecords == 1 && session.content?.queue.count == 1)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    private func key(_ value: String, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try workspaceRequire(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value,
            isARepeat: false, keyCode: 0))
    }
}
