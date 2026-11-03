import Combine
import Foundation
import Testing
@testable import Lingrove

/// These checks exercise the sidebar's asynchronous input boundary without opening a window
/// or repository. The real controller still decides whether a queued selection may navigate.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct NotebookWorkspaceNavigationTests {
    @Test("A selection never publishes or calls the window during its binding write")
    func selectionLeavesTheBindingWrite() async {
        let navigation = NotebookWorkspaceNavigation()
        defer { navigation.onSelect = nil }
        var isWritingBinding = true
        var publications = 0
        let subscription = navigation.objectWillChange.sink { publications += 1 }
        await withCheckedContinuation { continuation in
            navigation.onSelect = { destination in
                #expect(!isWritingBinding)
                #expect(destination == .review)
                navigation.show(destination)
                continuation.resume()
            }
            navigation.request(.review)
            #expect(publications == 0)
            #expect(navigation.destination == .corpus)
            isWritingBinding = false
        }
        #expect(navigation.destination == .review)
        #expect(publications == 1)
        subscription.cancel()
    }

    @Test("Only the latest queued selection reaches the window")
    func rapidSelectionsCoalesce() async {
        let navigation = NotebookWorkspaceNavigation()
        defer { navigation.onSelect = nil }
        var selections: [NotebookWorkspaceDestination] = []
        await withCheckedContinuation { continuation in
            navigation.onSelect = { destination in
                selections.append(destination)
                navigation.show(destination)
                if destination == .progress { continuation.resume() }
            }
            navigation.request(.review)
            navigation.request(.progress)
            #expect(selections.isEmpty)
        }
        #expect(selections == [.progress])
    }

    @Test("Returning to the current page revokes a queued departure")
    func currentSelectionCancelsDeparture() async throws {
        let navigation = NotebookWorkspaceNavigation()
        var selections: [NotebookWorkspaceDestination] = []
        navigation.onSelect = { selections.append($0) }
        navigation.request(.review)
        navigation.request(.corpus)
        try await Task.sleep(for: .milliseconds(30))
        #expect(selections.isEmpty)
        #expect(navigation.destination == .corpus)
    }

    @Test("A sheet blocks new requests and revokes already queued selections")
    func sheetRevokesSelection() async throws {
        let navigation = NotebookWorkspaceNavigation()
        var selections: [NotebookWorkspaceDestination] = []
        navigation.onSelect = { selections.append($0) }
        navigation.request(.review)
        navigation.hasSheet = true
        navigation.request(.progress)
        navigation.hasSheet = false
        try await Task.sleep(for: .milliseconds(30))
        #expect(selections.isEmpty)
        #expect(navigation.destination == .corpus)
    }

    @Test("A direct source opening supersedes a queued click, even on the current page")
    func directNavigationSupersedesSelection() async throws {
        let navigation = NotebookWorkspaceNavigation()
        var selections: [NotebookWorkspaceDestination] = []
        navigation.onSelect = { selections.append($0) }
        navigation.request(.review)
        navigation.show(.corpus)
        try await Task.sleep(for: .milliseconds(30))
        #expect(selections.isEmpty)
        #expect(navigation.destination == .corpus)
    }

    @Test("An obsolete cancelled job cannot clear a later window request")
    func cancellationKeepsTheNextRequest() async {
        let navigation = NotebookWorkspaceNavigation()
        defer { navigation.onSelect = nil }
        await withCheckedContinuation { continuation in
            navigation.onSelect = { destination in
                #expect(destination == .progress)
                navigation.show(destination)
                continuation.resume()
            }
            navigation.request(.review)
            navigation.cancelPendingRequest()
            navigation.request(.progress)
        }
        #expect(navigation.destination == .progress)
    }
}
