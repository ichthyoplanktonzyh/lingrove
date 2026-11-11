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

    /// One atomic Combine value avoids pairing a new sequence with stale invalidation flags.
    /// The repository owns it for its lifetime; subscribers still validate their durable owner.
    struct Change {
        let sequence: UInt64
        let domains: NotebookChangeDomains
    }
    @Published private(set) var change = Change(sequence: 0, domains: [])
    var changeSequence: UInt64 { change.sequence }
    private var lastChange: (version: LingroveNotebookVersion?, stamp: NotebookChangeStamp)?

    init(databaseURL: URL, mediaDirectoryURL: URL) throws {
        self.databaseURL = databaseURL
        self.mediaDirectoryURL = mediaDirectoryURL
        engine = try LingroveNotebookEngine(databaseURL: databaseURL, mediaDirectoryURL: mediaDirectoryURL)
        cloudStorage = NotebookEngineStorage(engine: engine)
        lastChange = try engine.notebookChanges()
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

    /// Hosts call after commits, including background connections. Derive flags from SQLite
    /// instead of trusting a caller's guess: a review command may also edit its source material.
    /// Probe failure broadcasts all domains so a stale screen cannot silently remain actionable.
    func publishChange() {
        var domains: NotebookChangeDomains = .all
        if let current = try? engine.notebookChanges() {
            if let previous = lastChange {
                let sameOwner: Bool
                switch (current.version, previous.version) {
                case let (.some(current), .some(previous)): sameOwner = current.hasSameOwner(as: previous)
                default: sameOwner = false
                }
                if sameOwner { domains = current.stamp.changes(since: previous.stamp) }
            }
            lastChange = current
        } else {
            lastChange = nil
        }
        change = Change(sequence: change.sequence &+ 1, domains: domains)
    }

    /// App termination owns connection retirement. Closing Settings or a vocabulary/review window
    /// must leave the engine, pending operations and account lifecycle available to the app.
    func shutdown() throws { try engine.close() }
}
