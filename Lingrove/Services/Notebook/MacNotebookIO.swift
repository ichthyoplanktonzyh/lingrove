import Foundation
import LingroveCloud
import LingroveNotebook
import LingroveNotebookEngine
import LingroveNotebookSync

/// The sync controller owns this serial worker alongside its network tasks. It borrows
/// repository URLs and opens its own short connections, keeping corpus decoding and
/// ownership merging away from MainActor. Every command retains its admitted generation.
actor MacNotebookIO {
    private let databaseURL: URL
    private let mediaDirectoryURL: URL
    private var isShutDown = false

    init(databaseURL: URL, mediaDirectoryURL: URL) {
        self.databaseURL = databaseURL
        self.mediaDirectoryURL = mediaDirectoryURL
    }

    func snapshot(version: LingroveNotebookVersion) throws -> LingroveNotebookSnapshot {
        try withEngine(readOnly: true) { engine in
            try engine.withNotebookRead(version: version) {
                try engine.lingroveNotebookStore.readSnapshot(workspaceId: version.workspaceId)
            }
        }
    }

    func ownership(version: LingroveNotebookVersion) throws
        -> (LingroveNotebookOwnershipProposal?, LingroveNotebookFirstConnection?) {
        try withEngine { engine in
            guard try engine.currentNotebookVersion() == version else { throw VocabularyError.editConflict }
            let proposal = try LingroveNotebookAccountStore(core: engine.core).proposal(workspaceID: version.workspaceId)
            let first = try engine.loadMacNotebookFirstConnection(version: version)
            guard try engine.currentNotebookVersion() == version else { throw VocabularyError.editConflict }
            return (proposal, first)
        }
    }

    func resolve(_ proposal: LingroveNotebookOwnershipProposal, merge: Bool,
                 choices: [Int: VocabularyWireConflictSelection.Choice]) throws {
        try withEngine { engine in
            _ = try LingroveNotebookAccountStore(core: engine.core).resolve(proposal, merge: merge, choices: choices)
        }
    }

    func resolveFirst(_ connection: LingroveNotebookFirstConnection, merge: Bool) throws {
        try withEngine { engine in
            try LingroveNotebookAccountStore(core: engine.core).resolveFirst(connection, merge: merge)
        }
    }

    func connect(workspace: CloudWorkspaceSummary, session: CloudLinkedSession, scheduler: WorkspaceSchedulerSettings,
                 source: LingroveNotebookSnapshot) throws {
        try withEngine { engine in
            _ = try engine.connectMacNotebookWorkspace(workspace: workspace, session: session,
                scheduler: scheduler, basedOn: source)
        }
    }

    func applyScheduler(_ settings: WorkspaceSchedulerSettings, version: LingroveNotebookVersion) throws {
        try withEngine { try $0.applyMacNotebookSchedulerSettings(settings, version: version) }
    }

    func firstConnection(version: LingroveNotebookVersion) throws -> LingroveNotebookFirstConnection? {
        try withEngine(readOnly: true) { try $0.loadMacNotebookFirstConnection(version: version) }
    }

    func mediaStatus(report: NotebookSyncReport) throws -> MacNotebookSyncStatus? {
        try withEngine(readOnly: true) { engine in
            let jobs = try LingroveNotebookMediaQueueStore(core: engine.core).jobs(
                binding: .init(scope: report.binding.scope, generation: report.binding.generation))
            if jobs.contains(where: { $0.state == .cancelled }) { return .cancelled }
            if jobs.contains(where: { $0.state == .failed || $0.state == .missing }) { return .pending }
            if jobs.contains(where: { $0.state != .ready }) { return .pending }
            return nil
        }
    }

    /// Entering this actor waits for its current synchronous database operation to retire.
    /// Cancelled queued tasks then fail admission before opening another connection.
    func shutdown() { isShutDown = true }

    private func withEngine<T>(readOnly: Bool = false, _ operation: (LingroveNotebookEngine) throws -> T) throws -> T {
        try Task.checkCancellation()
        guard !isShutDown else { throw CancellationError() }
        let engine = try readOnly
            ? LingroveNotebookEngine(readOnlyDatabaseURL: databaseURL, mediaDirectoryURL: mediaDirectoryURL)
            : LingroveNotebookEngine(databaseURL: databaseURL, mediaDirectoryURL: mediaDirectoryURL)
        defer { try? engine.close() }
        return try operation(engine)
    }
}
