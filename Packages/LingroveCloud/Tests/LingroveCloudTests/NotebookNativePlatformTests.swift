import Foundation
import LingroveCloud
import Testing

/// The real socket keeps a Mac pass in flight while another host declaration asks to borrow it.
/// Sharing an owner/workspace does not grant the right to reuse a different installation platform.
@MainActor
struct NotebookNativePlatformTests {
    @Test func anotherNativePlatformCannotBorrowAnExistingFlight() async throws {
        let server = try CloudLoopback(); defer { server.stop() }
        let storage = try RecordingNotebook()
        let coordinator = NotebookSyncCoordinator(storage: storage, mediaStorage: storage, reviewStorage: storage)
        let original = server.account
        let native = NotebookAccount(userID: original.userId, workspaceID: CloudFixture.workspace,
            apiBaseURL: original.apiBaseUrl, authorizationHeaderValue: original.authorizationHeaderValue,
            isAutomation: original.isAutomation, isTestDistribution: original.isTestDistribution, nativePlatform: .macos)
        try await server.mode("delay-caps")
        let flight = Task { try await coordinator.synchronize(native) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await !server.stats().paths.contains(where: { $0.hasSuffix("/capabilities") }) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
        await #expect(throws: NotebookStorageError.bindingChanged) { try await coordinator.synchronize(original) }
        _ = try await flight.value
    }
}
