import Foundation
import LingroveNotebook
import LingroveNotebookStorage
import SQLite3

/// LocalDatabase's notebook transaction owns this adapter. It borrows the existing registry,
/// cache and connection; original notebook PNGs never pass through Card's JPEG authoring path.
/// The workspace mapping grants access to bytes in the shared content-addressed blob cache.
public struct LingroveNotebookMediaStore {
    public let core: DatabaseCore

    /// File validation/publication happens before acquiring SQLite's writer lock. On failure
    /// we retain reusable blobs: deleting one could erase bytes a
    /// concurrent Card author just staged. No failed transaction leaves a visible notebook/map
    /// or upload operation; future GC must account for all notebook, Card and pending references.
    public func stageSuppliedImages(document: VocabularyDocument, supplied: [String: Data]) throws -> Set<VocabularyImageReference> {
        try VocabularyDocumentValidation.validateMediaContent(document)
        let references = Set(VocabularyDocumentValidation.imageReferences(document))
        guard references.reduce(0, { $0 + $1.byteCount }) <= VocabularyDocumentValidation.maximumMediaBytes else {
            throw VocabularyError.oversizedArchive
        }
        // Validate ALL supplied references before publishing any, so a malformed package does
        // not partially stage valid neighbours. The immutable dictionary needs no deep copy.
        let suppliedImages = references.compactMap { reference in supplied[reference.filename].map { (reference, $0) } }
        for (reference, bytes) in suppliedImages {
            try Task.checkCancellation()
            try VocabularyImageStorage.validate(bytes, reference: reference)
        }
        for (reference, bytes) in suppliedImages {
            try Task.checkCancellation()
            try self.publishValidated(bytes, reference: reference)
        }
        return Set(suppliedImages.map { $0.0 })
    }

    /// The caller holds the notebook write transaction. Only registry/mapping changes and
    /// occasional reads of an explicitly reused owned image run while that lock is held.
    public func registerImages(
        document: VocabularyDocument, previous: VocabularyDocument, staged: Set<VocabularyImageReference>, workspaceId: String
    ) throws {
        let references = Set(VocabularyDocumentValidation.imageReferences(document))
        let existing = Set(VocabularyDocumentValidation.imageReferences(previous))
        for reference in references {
            try Task.checkCancellation()
            let mapped = try self.assetId(reference, workspaceId: workspaceId)
            if !staged.contains(reference) {
                // A digest alone cannot import bytes owned only by another workspace, even
                // though the physical cache deduplicates both workspaces' files by hash.
                guard let mapped else { throw VocabularyError.invalidContent }
                if existing.contains(reference), try self.hasRegisteredBytesMetadata(reference, assetId: mapped, workspaceId: workspaceId) {
                    continue
                }
                _ = try self.readBlob(reference)
            }
            let identifier = mapped ?? UUID().uuidString.lowercased()
            try self.register(reference, assetId: identifier, workspaceId: workspaceId)
        }
        try LingroveNotebookMediaQueueStore(core: core).replacePins(Array(references), workspaceID: workspaceId, consumer: "document")
    }

    /// Transfer IO uses these small primitives without weakening ownership.
    /// Staging is content-addressed and grants no access; registration is called
    /// only inside a binding-fenced queue transaction after PNG validation.
    public func stageImage(_ bytes: Data, reference: VocabularyImageReference) throws {
        try VocabularyImageStorage.validate(bytes, reference: reference)
        try publishValidated(bytes, reference: reference)
    }

    public func registerImage(_ reference: VocabularyImageReference, workspaceId: String) throws {
        let identifier = try assetId(reference, workspaceId: workspaceId) ?? UUID().uuidString.lowercased()
        try register(reference, assetId: identifier, workspaceId: workspaceId)
    }

    /// Caller owns a read or write transaction. A shared hash cache hit without
    /// this workspace's mapping must never be accepted by a download planner.
    public func ownedImage(_ reference: VocabularyImageReference, workspaceId: String) throws -> Data {
        guard let id = try assetId(reference, workspaceId: workspaceId),
              try hasRegisteredBytesMetadata(reference, assetId: id, workspaceId: workspaceId) else { throw VocabularyError.invalidContent }
        return try readBlob(reference)
    }

    public func image(_ reference: VocabularyImageReference, scope: LingroveNotebookSnapshot, requireActiveWorkspace: Bool = false) throws -> Data {
        try self.core.inReadTransaction {
            try imageInTransaction(reference, scope: scope, requireActiveWorkspace: requireActiveWorkspace)
        }
    }

    /// A full backup already holds a read snapshot across document and media.
    /// Borrow that transaction instead of attempting a nested BEGIN.
    public func imageInTransaction(_ reference: VocabularyImageReference, scope: LingroveNotebookSnapshot, requireActiveWorkspace: Bool = false) throws -> Data {
        try validateScopeInTransaction(scope, requireActiveWorkspace: requireActiveWorkspace)
        guard let assetId = try self.assetId(reference, workspaceId: scope.workspaceId),
              try self.hasRegisteredBytesMetadata(reference, assetId: assetId, workspaceId: scope.workspaceId) else {
            throw VocabularyError.invalidContent
        }
        return try self.readBlob(reference)
    }

    public func validateScope(_ scope: LingroveNotebookSnapshot, requireActiveWorkspace: Bool) throws {
        try core.inReadTransaction { try validateScopeInTransaction(scope, requireActiveWorkspace: requireActiveWorkspace) }
    }
    private func validateScopeInTransaction(_ scope: LingroveNotebookSnapshot, requireActiveWorkspace: Bool) throws {
        guard try LingroveNotebookLocalScopeStore(core: core).generationInTransaction() == scope.generation else {
            throw VocabularyError.editConflict
        }
        if requireActiveWorkspace {
            guard try self.core.scalarOptionalText(sql: "SELECT active_workspace_id FROM app_local_settings WHERE settings_id=1",
                values: []) == scope.workspaceId else { throw VocabularyError.editConflict }
        }
        guard try self.core.scalarOptionalText(sql: "SELECT notebook_id FROM notebook_state WHERE workspace_id=?",
            values: [.text(scope.workspaceId)]) == scope.notebookId.uuidString else {
            throw VocabularyError.invalidContent
        }
    }

    private func assetId(_ reference: VocabularyImageReference, workspaceId: String) throws -> String? {
        guard VocabularyContentPolicy.valid(reference) else { throw VocabularyError.invalidContent }
        return try self.core.query(sql: """
            SELECT media_asset_id,width,height,byte_count FROM notebook_media_assets WHERE workspace_id=? AND digest=?
            """, values: [.text(workspaceId), .text(reference.digest)]) { statement in
            let id = DatabaseCore.columnText(statement: statement, index: 0)
            guard UUID(uuidString: id) != nil,
                  (1...3).allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }),
                  sqlite3_column_int64(statement, 1) == reference.width,
                  sqlite3_column_int64(statement, 2) == reference.height,
                  sqlite3_column_int64(statement, 3) == reference.byteCount else { throw VocabularyError.invalidContent }
            return id
        }.first
    }

    private func hasRegisteredBytesMetadata(_ reference: VocabularyImageReference, assetId: String, workspaceId: String) throws -> Bool {
        guard let asset = try MediaAssetStore(core: self.core).loadOptionalMediaAssetIncludingDeleted(
            workspaceId: workspaceId, mediaAssetId: assetId), asset.deletedAt == nil,
              asset.sha256 == reference.digest, asset.mimeType == "image/png", asset.sizeBytes == reference.byteCount,
              let cached = try MediaTransferStore(core: self.core).loadOptionalBlobCacheEntry(sha256: reference.digest),
              cached.mimeType == "image/png", cached.sizeBytes == reference.byteCount,
              cached.localRelativePath == (try mediaBlobCacheRelativePath(sha256: reference.digest)) else { return false }
        return true
    }

    private func register(_ reference: VocabularyImageReference, assetId: String, workspaceId: String) throws {
        let now = nowIsoTimestamp()
        let old = try MediaAssetStore(core: self.core).loadOptionalMediaAssetIncludingDeleted(workspaceId: workspaceId, mediaAssetId: assetId)
        let installation = try WorkspaceSettingsStore(core: self.core).loadCloudSettings().installationId
        let asset = MediaAsset(mediaAssetId: assetId, workspaceId: workspaceId, mimeType: "image/png",
            sizeBytes: Int64(reference.byteCount), sha256: reference.digest, sourceUrl: nil,
            createdAt: old?.createdAt ?? now, clientUpdatedAt: now,
            lastModifiedByReplicaId: mediaUploadWorkspaceReplicaId(workspaceId: workspaceId, installationId: installation),
            lastOperationId: UUID().uuidString.lowercased(), updatedAt: now, deletedAt: nil)
        try MediaAssetStore(core: self.core).upsertMediaAsset(workspaceId: workspaceId, mediaAsset: asset)
        _ = try MediaTransferStore(core: self.core).upsertBlobCacheEntry(entry: .init(sha256: reference.digest,
            mimeType: "image/png", sizeBytes: Int64(reference.byteCount), createdAt: now, lastAccessedAt: now, sourceMediaAssetId: assetId))
        try self.core.execute(sql: """
            INSERT INTO notebook_media_assets(workspace_id,digest,media_asset_id,width,height,byte_count)
            VALUES(?,?,?,?,?,?) ON CONFLICT(workspace_id,digest) DO NOTHING
            """, values: [.text(workspaceId), .text(reference.digest), .text(assetId), .integer(Int64(reference.width)),
                .integer(Int64(reference.height)), .integer(Int64(reference.byteCount))])
        // Deliberately no legacy Card outbox/transfer enqueue. Notebook synchronization must
        // publish its own atomic graph plus media contract before these resources can upload.
    }

    private func blobURL(_ reference: VocabularyImageReference) throws -> URL {
        self.core.mediaDirectoryURL.appendingPathComponent(
            try mediaBlobCacheRelativePath(sha256: reference.digest), isDirectory: false)
    }

    private func readBlob(_ reference: VocabularyImageReference) throws -> Data {
        let data = try VocabularyImageStorage.boundedRead(self.blobURL(reference), maximum: VocabularyContentPolicy.maximumImageBytes)
        try VocabularyImageStorage.validate(data, reference: reference)
        return data
    }

    private func publishValidated(_ bytes: Data, reference: VocabularyImageReference) throws {
        let target = try self.blobURL(reference)
        var directory = self.core.mediaDirectoryURL
        let components = try mediaBlobCacheRelativePath(sha256: reference.digest).split(separator: "/").dropLast()
        for component in components {
            directory.appendPathComponent(String(component), isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                } catch {
                    // A Card/download writer may have created this same parent after our
                    // existence check. Accept only a real directory; never follow a symlink.
                    let created = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard created?.isDirectory == true, created?.isSymbolicLink != true else { throw error }
                }
            }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw VocabularyError.invalidContent }
        }
        if FileManager.default.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VocabularyError.invalidContent }
            if (try? self.readBlob(reference)) != nil { return }
        }
        // Atomic replacement can repair corrupt bytes with the same immutable content identity.
        // It never removes or rewrites any different digest and strips no further PNG metadata.
        try bytes.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    public init(core: DatabaseCore) {
        self.core = core
    }
}
