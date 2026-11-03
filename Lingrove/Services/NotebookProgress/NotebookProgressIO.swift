import Foundation
import LingroveNotebookEngine

/// One customization point for delayed/failing integration reads. Production uses the actor
/// below; tests can pause an actual saved result to verify cancellation and account fences.
nonisolated protocol NotebookProgressReading: Sendable {
    func load(scope: NotebookProgressScope, now: Date, calendar: Calendar) async throws -> NotebookProgressContent
}

/// The Progress destination owns this read worker, borrowing only the repository's file URLs.
/// Each read opens a native read-only handle and retires it before returning immutable data.
/// It cannot bootstrap, purge, repair, submit reviews or start account/cloud work.
actor NotebookProgressIO: NotebookProgressReading {
    private let databaseURL: URL
    private let mediaDirectoryURL: URL

    init(databaseURL: URL, mediaDirectoryURL: URL) {
        self.databaseURL = databaseURL
        self.mediaDirectoryURL = mediaDirectoryURL
    }

    func load(scope: NotebookProgressScope, now: Date, calendar: Calendar) throws -> NotebookProgressContent {
        try Task.checkCancellation()
        let engine = try LingroveNotebookEngine(readOnlyDatabaseURL: databaseURL,
            mediaDirectoryURL: mediaDirectoryURL)
        defer { try? engine.close() }
        let snapshot = try engine.loadNotebookProgress(scope: scope, now: now, calendar: calendar)
        try Task.checkCancellation()
        return try NotebookProgressPresentationFactory.make(snapshot)
    }
}
