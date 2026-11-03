import AppKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import Testing
@testable import Lingrove

/// Explicitly enabled for one short computer-use handoff. The actual production workspace starts
/// with saved corpus and zero enrollment; the operator must opt in, practice and return to corpus
/// and the existing settings account page. Database assertions distinguish real writes from UI.
@Suite(.serialized, .timeLimit(.minutes(15)))
@MainActor
struct NotebookWorkspaceOnscreenAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_ONSCREEN"] != nil))
    func visibleEnrollmentReviewAndSettingsJourney() async throws {
        let output = URL(fileURLWithPath: try workspaceRequire(ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_ONSCREEN"]))
        let fixture = try NotebookWorkspaceFixture()
        do {
            let selection = try await fixture.seed()
            let scope = try fixture.repository.snapshot()
            workspaceExpect(try fixture.repository.engine.loadActiveCardCount(workspaceId: scope.workspaceId) == 0)
            fixture.window.show(selectedID: selection.entryID, senseID: selection.senseID)
            let window = try workspaceRequire(fixture.window.window)
            window.setContentSize(.init(width: 1240, height: 760))
            window.center()
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "database": fixture.repository.databaseURL.path,
                "windowTitle": window.title,
                "initialCards": 0,
                "done": output.appendingPathComponent("done.json").path
            ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("ready.json"))
            let done = output.appendingPathComponent("done.json")
            for _ in 0..<6000 {
                if FileManager.default.fileExists(atPath: done.path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try workspaceRequire(FileManager.default.fileExists(atPath: done.path), "The visible workspace handoff did not complete")
            let final = try fixture.repository.snapshot()
            let actual = try fixture.repository.engine.loadBuiltInNotebookReview(scope: final, now: Date())
            workspaceExpect(actual.statistics.activeSenses == 1 && actual.statistics.exercises == 1)
            workspaceExpect(actual.statistics.ratingRecords == 1 && actual.statistics.undoneRatings == 0)
            workspaceExpect(actual.review.groups[selection.senseID]?.cards.first?.reps == 1)
            workspaceExpect(fixture.window.navigation.destination == .corpus)
            workspaceExpect(fixture.window.corpusHost?.rootView.selectedID == selection.entryID)
            workspaceExpect(fixture.settingsWindow?.isVisible == true)
            try JSONSerialization.data(withJSONObject: [
                "activeSenses": actual.statistics.activeSenses,
                "exercises": actual.statistics.exercises,
                "ratingRecords": actual.statistics.ratingRecords,
                "undoneRatings": actual.statistics.undoneRatings,
                "reps": actual.review.groups[selection.senseID]?.cards.first?.reps ?? -1,
                "corpusDestination": fixture.window.navigation.destination == .corpus,
                "settingsVisible": fixture.settingsWindow?.isVisible == true,
                "accountRequired": false,
                "originalCorpusSourceSelected": fixture.window.corpusHost?.rootView.selectedSenseID == selection.senseID
            ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("stored-result.json"))
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }
}
