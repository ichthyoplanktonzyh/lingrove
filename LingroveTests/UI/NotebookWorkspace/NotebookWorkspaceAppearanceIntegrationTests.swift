import AppKit
import Foundation
import LingroveNotebookEngine
import Testing
@testable import Lingrove

/// Integration owns the actual split host and Settings coordinator together. Unlike isolated
/// destination renders, this catches a host-level override surviving a page switch after the
/// account and review modules are combined. Only private windows receive an explicit appearance;
/// neither the system nor the user's application or corpus participates in the test.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct NotebookWorkspaceAppearanceIntegrationTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func combinedDestinationsAndSettingsRetainInheritedAppearance(_ appearance: NSAppearance.Name) async throws {
        let fixture = try NotebookWorkspaceFixture(usesRealProgress: true)
        let applicationAppearance = NSApplication.shared.appearance?.name
        do {
            let selection = try await fixture.seed()
            fixture.window.show(selectedID: selection.entryID, senseID: selection.senseID)
            let window = try workspaceRequire(fixture.window.window)
            window.appearance = NSAppearance(named: appearance)
            window.setFrameOrigin(.init(x: -3000, y: -3000))
            let corpus = try workspaceRequire(fixture.window.corpusHost)
            let suffix = appearance == .darkAqua ? "dark" : "light"

            for destination in [NotebookWorkspaceDestination.corpus, .review, .progress, .corpus] {
                fixture.window.navigate(to: destination)
                if destination == .review { await fixture.review.session.waitForIdle() }
                try await captureWorkspace(window, name: "combined-\(destination.rawValue)-\(suffix)")
                workspaceExpect(window.title == NotebookWorkspaceCopy.title(destination))
                workspaceExpect(window.appearance?.name == appearance)
                try checkInheritedHosts(workspaceRequire(window.contentViewController), appearance: appearance)
                workspaceExpect(fixture.window.corpusHost === corpus)
            }

            fixture.window.onShowAccount?()
            let settings = try workspaceRequire(fixture.settingsWindow)
            let coordinator = try workspaceRequire(fixture.settings)
            settings.appearance = NSAppearance(named: appearance)
            settings.setFrameOrigin(.init(x: -3000, y: -3000))
            coordinator.navigation.account.show(.service)
            try await captureWorkspace(settings, name: "combined-service-\(suffix)")
            fixture.window.onShowAccount?()
            workspaceExpect(fixture.settingsWindow === settings)
            workspaceExpect(coordinator.navigation.selection == .account)
            workspaceExpect(coordinator.navigation.account.path.isEmpty)
            try await captureWorkspace(settings, name: "combined-account-\(suffix)")
            coordinator.navigation.open(.appearance)
            try await captureWorkspace(settings, name: "combined-other-settings-\(suffix)")
            workspaceExpect(settings.appearance?.name == appearance)
            try checkInheritedHosts(workspaceRequire(settings.contentViewController), appearance: appearance)
            workspaceExpect(NSApplication.shared.appearance?.name == applicationAppearance)
            workspaceExpect(!fixture.sync.enabled)
            let snapshot = try fixture.repository.snapshot()
            workspaceExpect(try fixture.repository.engine.loadActiveCardCount(workspaceId: snapshot.workspaceId) == 0)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    /// The production containment tree exposes the active hosts. Checking their explicit and
    /// effective appearances detects a child override even when the outer window stayed Aqua.
    private func checkInheritedHosts(_ controller: NSViewController, appearance: NSAppearance.Name) throws {
        workspaceExpect(controller.view.appearance == nil)
        workspaceExpect(controller.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
        for child in controller.children where child.view.window != nil {
            try checkInheritedHosts(child, appearance: appearance)
        }
    }
}
