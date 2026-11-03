import Combine
import Foundation
import LingroveNotebook
import LingroveNotebookCloud
import LingroveNotebookEngine

/// The native app's single long-lived notebook resource, built by LingroveAppEnvironment. Capture,
/// CLI, account/sync and review receive this same reference; no window creates another library.
/// The portable engine owns transactions and the cloud adapter opens only short-lived connections
/// to this same file for background work. No account request or adoption starts in this initializer.
@MainActor
final class MacNotebookRepository: ObservableObject {
    nonisolated let databaseURL: URL
    nonisolated let mediaDirectoryURL: URL
    let engine: LingroveNotebookEngine
    let cloudStorage: NotebookEngineStorage

    /// A notification counter, never a database revision or account identity. Views reload their
    /// saved snapshots after a committed edit, sync or scope change and compare durable generation.
    @Published private(set) var changeSequence: UInt64 = 0

    init(databaseURL: URL, mediaDirectoryURL: URL) throws {
        self.databaseURL = databaseURL
        self.mediaDirectoryURL = mediaDirectoryURL
        engine = try LingroveNotebookEngine(databaseURL: databaseURL, mediaDirectoryURL: mediaDirectoryURL)
        cloudStorage = NotebookEngineStorage(engine: engine)
    }

    func snapshot() throws -> LingroveNotebookSnapshot {
        let settings = try engine.workspaceSettingsStore.loadCloudSettings()
        guard let workspace = settings.activeWorkspaceId else { throw VocabularyError.editConflict }
        return try engine.lingroveNotebookStore.load(workspaceId: workspace, requireActiveWorkspace: true)
    }

    /// Admission and change notifications consume only metadata. A fresh workspace creates its
    /// empty notebook once; ordinary saves never decode the corpus on MainActor for these checks.
    func version() throws -> LingroveNotebookVersion {
        if let version = try engine.currentNotebookVersion() { return version }
        return try LingroveNotebookVersion(snapshot())
    }

    /// Hosts call this only after a durable commit. It carries no content and does not authorize
    /// another write; the receiving screen must capture the new workspace/revision/generation.
    func publishChange() { changeSequence &+= 1 }

    /// App termination owns connection retirement. Closing Settings or a vocabulary/review window
    /// must leave the engine, pending operations and account lifecycle available to the app.
    func shutdown() throws { try engine.close() }
}
