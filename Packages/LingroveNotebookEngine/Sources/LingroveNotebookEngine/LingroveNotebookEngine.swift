import Foundation

/// Portable corpus and built-in review transaction owner. Each host creates one facade per
/// SQLite connection. It does not create authentication, network, UI, timers or a guest session.
/// The owning initializer opens the supplied location; mobile borrows its existing Core so
/// notebook edits, generated faces, immutable ratings and all journals share one writer lock.
public final class LingroveNotebookEngine {
    private let ownsConnection: Bool
    public let core: DatabaseCore
    public var databaseURL: URL { core.databaseURL }
    public let cardStore: CardStore
    public let lingroveNotebookStore: LingroveNotebookStore
    public let lingroveNotebookWindowStore: LingroveNotebookWindowStore
    public let lingroveNotebookSyncStore: LingroveNotebookSyncStore
    public let lingroveNotebookUploadStore: LingroveNotebookUploadStore
    public let lingroveNotebookCardLinkStore: LingroveNotebookCardLinkStore
    public let lingroveNotebookReviewStore: LingroveNotebookReviewStore
    public let deckStore: DeckStore
    public let mediaAssetStore: MediaAssetStore
    public let mediaTransferStore: MediaTransferStore
    public let outboxStore: OutboxStore
    public let syncApplier: SyncApplier
    public let workspaceSettingsStore: WorkspaceSettingsStore

    /// A newly owned database uses the complete current schema extracted from the mobile
    /// checkpoint. Unsupported schema versions fail without deleting or rewriting user data.
    public convenience init(databaseURL: URL, mediaDirectoryURL: URL) throws {
        let core = try DatabaseCore(databaseURL: databaseURL, mediaDirectoryURL: mediaDirectoryURL) { core in
            let version = try core.scalarInt(sql: "PRAGMA user_version", values: [])
            guard version == 0 || version == LocalDatabaseSchema.currentVersion else {
                throw LocalStoreError.database("Unsupported notebook engine schema version: \(version)")
            }
            if version == 0 {
                try core.inTransaction {
                    try core.executeScript(sql: LocalDatabaseSchema.baseMigrationSQL, errorContext: "Create notebook engine schema")
                    try core.executeScript(sql: "PRAGMA user_version = \(LocalDatabaseSchema.currentVersion)", errorContext: "Record notebook engine schema")
                }
            }
            return try LocalDatabaseBootstrapper(core: core).ensureDefaultState()
        }
        try self.init(core: core, ownsConnection: true)
    }

    /// Borrowing never opens a second handle and never migrates the host's database.
    public convenience init(borrowing core: DatabaseCore) throws {
        try self.init(core: core, ownsConnection: false)
    }

    /// Short-lived analytical readers use the existing schema without bootstrap or housekeeping
    /// writes. They still receive the same guarded stores and SQL rules; the native read-only
    /// connection rejects mutations even if a caller accidentally invokes a command on it.
    public convenience init(readOnlyDatabaseURL: URL, mediaDirectoryURL: URL) throws {
        let core = try DatabaseCore(readOnlyDatabaseURL: readOnlyDatabaseURL, mediaDirectoryURL: mediaDirectoryURL)
        do {
            let version = try core.scalarInt(sql: "PRAGMA user_version", values: [])
            guard version == LocalDatabaseSchema.currentVersion else {
                throw LocalStoreError.database("Unsupported notebook engine schema version: \(version)")
            }
            try self.init(core: core, ownsConnection: true, performsMaintenance: false)
        } catch {
            try? core.close()
            throw error
        }
    }

    private init(core: DatabaseCore, ownsConnection: Bool, performsMaintenance: Bool = true) throws {
        self.ownsConnection = ownsConnection
        self.core = core
        self.cardStore = CardStore(core: core)
        self.lingroveNotebookStore = LingroveNotebookStore(core: core)
        self.lingroveNotebookWindowStore = LingroveNotebookWindowStore(core: core)
        self.lingroveNotebookSyncStore = LingroveNotebookSyncStore(core: core)
        self.lingroveNotebookUploadStore = LingroveNotebookUploadStore(core: core)
        self.lingroveNotebookCardLinkStore = LingroveNotebookCardLinkStore(core: core)
        self.lingroveNotebookReviewStore = LingroveNotebookReviewStore(core: core)
        self.deckStore = DeckStore(core: core)
        self.mediaAssetStore = MediaAssetStore(core: core)
        self.mediaTransferStore = MediaTransferStore(core: core)
        self.outboxStore = OutboxStore(core: core)
        self.syncApplier = SyncApplier(core: core)
        self.workspaceSettingsStore = WorkspaceSettingsStore(core: core)
        if performsMaintenance { try self.lingroveNotebookWindowStore.purgeExpired(now: Date()) }
    }

    /// Closing a borrowed facade never retires its host's connection. The host still owns all
    /// other adapters on that handle and closes it through its own lifetime boundary.
    public func close() throws { if ownsConnection { try core.close() } }
}
