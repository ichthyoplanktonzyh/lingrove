import AppKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import Testing
@testable import Lingrove

/// Explicitly enabled for short computer-use handoffs in a private production workspace. The
/// full journey starts without enrollment; the navigation regression prepares a rated sense
/// through the existing service commands so the operator can focus on sidebar responsiveness.
/// Database assertions distinguish real writes from UI and protect the user's installed corpus.
@Suite(.serialized, .timeLimit(.minutes(15)))
@MainActor
struct NotebookWorkspaceOnscreenAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_ONSCREEN"] != nil))
    func visibleSettingsSidebarNavigationRemainsResponsive() async throws {
        let output = URL(fileURLWithPath: try workspaceRequire(ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_ONSCREEN"]))
        try #require(Bundle.main.object(forInfoDictionaryKey: "LingroveIsolatedValidationHost") as? Bool == true)
        // AppStorage belongs to the private host's standard domain, rather than the corpus
        // fixture's injected preferences. Freeze that host-only initial pane across reruns.
        let key = "lingroveSettingsSelectedCategoryV2"
        let previousPane = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(SettingsCategory.home.rawValue, forKey: key)
        defer {
            if let previousPane { UserDefaults.standard.set(previousPane, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let fixture = try NotebookWorkspaceFixture()
        do {
            fixture.window.onShowSettings?()
            let window = try workspaceRequire(fixture.settingsWindow)
            let navigation = try workspaceRequire(fixture.settings).navigation
            navigation.open(.home)
            window.center()
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var selections: [SettingsCategory] = []
            let subscription = navigation.$selection.dropFirst().sink { category in
                // Settings restores its remembered pane during the first mount. Count actual
                // transitions, not a repeated initial Home publication before the first click.
                if category != (selections.last ?? .home) { selections.append(category) }
            }
            defer { subscription.cancel() }
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                "expectedPanes": ["general", "appearance", "permissions", "home"]],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("settings-navigation-ready.json"))
            let expected: [SettingsCategory] = [.general, .appearance, .permissions, .home]
            for _ in 0..<1800 {
                if selections.count >= expected.count { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            workspaceExpect(selections == expected)
            workspaceExpect(navigation.selection == .home)
            try await captureWorkspace(window, name: "settings-sidebar-responsive-final")
            try JSONSerialization.data(withJSONObject: ["panes": selections.map(\.rawValue)],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("settings-navigation-result.json"))
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_ONSCREEN"] != nil))
    func visibleSidebarNavigationRemainsResponsive() async throws {
        let output = URL(fileURLWithPath: try workspaceRequire(ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_ONSCREEN"]))
        let fixture = try NotebookWorkspaceFixture(usesRealProgress: true)
        do {
            let selection = try await fixture.seed()
            fixture.review.show(selection: selection)
            let session = fixture.review.session
            await session.waitForIdle()
            session.enrollDefault(selection: selection, basedOn: try workspaceRequire(session.content))
            await session.waitForIdle()
            session.start()
            session.reveal()
            session.rate(.good)
            await session.waitForIdle()
            fixture.window.navigate(to: .corpus)
            let window = try workspaceRequire(fixture.window.window)
            window.setContentSize(.init(width: 1240, height: 760))
            window.center()
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var destinations: [NotebookWorkspaceDestination] = []
            let subscription = fixture.window.navigation.$destination.dropFirst().sink { destinations.append($0) }
            defer { subscription.cancel() }
            try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "windowTitle": window.title,
                "expectedDestinations": ["review", "progress", "corpus", "review", "progress", "corpus"]
            ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("navigation-ready.json"))
            let expected: [NotebookWorkspaceDestination] = [.review, .progress, .corpus, .review, .progress, .corpus]
            for _ in 0..<1800 {
                if destinations.count >= expected.count { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            workspaceExpect(destinations == expected, "The actual sidebar must finish two navigation cycles within three minutes")
            workspaceExpect(fixture.window.navigation.destination == .corpus)
            workspaceExpect(window.toolbar?.items.isEmpty == false)
            let scope = try fixture.repository.snapshot()
            let events = try fixture.repository.engine.loadReviewEvents(workspaceId: scope.workspaceId)
            workspaceExpect(events.count == 1, "Sidebar navigation must not duplicate the fixture's accepted rating")
            try await captureWorkspace(window, name: "sidebar-responsive-final")
            try JSONSerialization.data(withJSONObject: [
                "destinations": destinations.map(\.rawValue), "ratingEvents": events.count,
                "corpusToolbarRestored": window.toolbar?.items.isEmpty == false
            ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("navigation-result.json"))
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_ONSCREEN"] != nil))
    func visibleEnrollmentReviewAndSettingsJourney() async throws {
        let output = URL(fileURLWithPath: try workspaceRequire(ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_ONSCREEN"]))
        let fixture = try NotebookWorkspaceFixture(usesRealProgress: true)
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
            // This final read crosses the real Progress actor after the visible review journey.
            // It confirms the two delivered modules describe the same persisted rating.
            let progressFence = try fixture.repository.engine.notebookProgressReadFence()
            let progress = try await NotebookProgressIO(databaseURL: fixture.repository.databaseURL,
                mediaDirectoryURL: fixture.repository.mediaDirectoryURL)
                .load(scope: progressFence.scope, now: Date(), calendar: .current)
            workspaceExpect(progress.snapshot.totalReviews == 1 && progress.snapshot.activeSenses == 1)
            try JSONSerialization.data(withJSONObject: [
                "activeSenses": actual.statistics.activeSenses,
                "exercises": actual.statistics.exercises,
                "ratingRecords": actual.statistics.ratingRecords,
                "undoneRatings": actual.statistics.undoneRatings,
                "reps": actual.review.groups[selection.senseID]?.cards.first?.reps ?? -1,
                "corpusDestination": fixture.window.navigation.destination == .corpus,
                "settingsVisible": fixture.settingsWindow?.isVisible == true,
                "accountRequired": false,
                "progressReviews": progress.snapshot.totalReviews,
                "progressActiveSenses": progress.snapshot.activeSenses,
                "originalCorpusSourceSelected": fixture.window.corpusHost?.rootView.selectedSenseID == selection.senseID
            ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("stored-result.json"))
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }
}
