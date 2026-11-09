import AppKit
import Foundation
import LingroveCloud
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// An explicitly enabled, private native host lets the integration owner inspect compositor
/// glass and perform a short mouse journey. Fixture setup uses validated commands; actual reveal
/// and rating come from the visible production views. No installed app or user corpus is opened.
@Suite(.serialized, .timeLimit(.minutes(15)))
@MainActor
struct MacWave3OnscreenAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINGROVE_MAC_W3_ONSCREEN"] != nil))
    func visibleReviewAndAccountJourney() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LINGROVE_MAC_W3_ONSCREEN"]))
        let fixture = try MacNotebookSyncFixture()
        let store = VocabularyStore(repository: fixture.repository)
        let review = BuiltInReviewController(repository: fixture.repository)
        let accountWindow = NSWindow(contentRect: .init(x: 120, y: 120, width: 820, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        accountWindow.isReleasedWhenClosed = false
        accountWindow.title = "Mac Wave3 Account"
        accountWindow.contentView = NSHostingView(rootView: AccountPaneView(account: fixture.account,
            syncController: fixture.sync))
        do {
            await store.save(.init(expression: "harbor", dictionaryForm: "harbor", language: .english,
                kind: .word, meaning: "a sheltered place for boats", meaningLanguage: .english))
            let saved = try fixture.repository.snapshot()
            let entry = try #require(saved.document.entries.first)
            let selection = VocabularySelection(entryID: entry.id, senseID: entry.senses[0].id)
            #expect(try fixture.repository.engine.loadLingroveNotebookReviewEnrollments(workspaceId: saved.workspaceId).isEmpty)
            let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
            _ = try fixture.repository.engine.enrollNotebookSenses([draft], basedOn: saved)
            fixture.repository.publishChange()
            fixture.start()
            #expect(fixture.account.configure(api: fixture.server.configuration.apiBaseURL.absoluteString,
                auth: fixture.server.configuration.authBaseURL.absoluteString))
            accountWindow.makeKeyAndOrderFront(nil)
            review.show()
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                "database": fixture.repository.databaseURL.path, "accountWindow": accountWindow.title,
                "done": output.appendingPathComponent("done.json").path], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("ready.json"))
            let done = output.appendingPathComponent("done.json")
            // This opt-in host waits for a human/computer-use handoff, not product work. Its
            // deadline is deliberately separate from the normal deterministic test suites.
            for _ in 0..<6000 {
                if FileManager.default.fileExists(atPath: done.path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(FileManager.default.fileExists(atPath: done.path), "Visible interaction was not completed")
            let events = try fixture.repository.engine.loadReviewEvents(workspaceId: saved.workspaceId)
            #expect(events.count == 1)
            let enrollment = try #require(try fixture.repository.engine
                .loadLingroveNotebookReviewEnrollments(workspaceId: saved.workspaceId).first)
            let exercise = try #require(try fixture.repository.engine.lingroveNotebookReviewStore.exercises(enrollment).first)
            let rated = try fixture.repository.engine.loadActiveCard(workspaceId: saved.workspaceId, cardId: exercise.cardId)
            #expect(rated.reps == 1)
            await store.load()
            let before = try #require(store.entries.first)
            var edited = before
            edited.senses[0].meaning = "a safe anchorage"
            #expect(await store.update(edited, basedOn: before))
            let after = try fixture.repository.engine.loadActiveCard(workspaceId: saved.workspaceId, cardId: exercise.cardId)
            #expect(after.reps == rated.reps && after.dueAt == rated.dueAt && after.backText == "a safe anchorage")
            try JSONSerialization.data(withJSONObject: ["ratingRecords": events.count, "reps": after.reps,
                "sourceFollowedAfterEntrySave": after.backText == "a safe anchorage", "accountRequiredForReview": false],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("stored-result.json"))
            await review.shutdownAfterDraining()
            accountWindow.close()
            await store.shutdown()
            fixture.cleanup()
        } catch {
            await review.shutdownAfterDraining()
            accountWindow.close()
            await store.shutdown()
            fixture.cleanup()
            throw error
        }
    }
}
