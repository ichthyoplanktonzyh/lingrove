import Foundation
import LingroveNotebook
import LingroveNotebookStorage

/// Review resources are bounded SQLite-owned blobs, committed with recipe, Card and link. This
/// separate owner avoids pre-save cache publication and keeps cancellation/rollback write-free.
/// The generic MediaAsset registry supplies native rendering metadata; only this held review
/// lane may publish these bytes, and workspace scope remains part of every lookup.
public struct LingroveNotebookReviewMediaStore {
    public let core: DatabaseCore
    public init(core: DatabaseCore) { self.core = core }

    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_review_media (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            digest TEXT NOT NULL CHECK(length(digest)=64),
            media_asset_id TEXT NOT NULL,
            reference_json TEXT NOT NULL,
            bytes_base64 TEXT NOT NULL CHECK(length(bytes_base64)<=5592408),
            acknowledged INTEGER NOT NULL DEFAULT 0 CHECK(acknowledged IN (0,1)),
            PRIMARY KEY(workspace_id,digest), UNIQUE(workspace_id,media_asset_id)
        );
        """
    public static let resetSQL = "DROP TABLE IF EXISTS notebook_review_media;"

    public static func validate(_ prepared: ReviewMaterialPreparedMedia) throws {
        let reference = prepared.reference, bytes = prepared.data
        guard reference.isValid, bytes.count == reference.byteCount,
              ReviewMaterialMediaReference.digest(bytes) == reference.digest else { throw VocabularyError.invalidContent }
        if let image = reference.image { try VocabularyImageStorage.validate(bytes, reference: image); return }
        let prefix = Array(bytes.prefix(12))
        switch reference.mimeType {
        case "audio/wav":
            guard bytes.count >= 44, Array(prefix[0..<4]) == Array("RIFF".utf8), Array(prefix[8..<12]) == Array("WAVE".utf8) else { throw VocabularyError.invalidContent }
        case "audio/mpeg":
            guard bytes.count >= 4, bytes.starts(with: Data("ID3".utf8)) || (prefix[0] == 0xff && prefix[1] & 0xe0 == 0xe0) else { throw VocabularyError.invalidContent }
        default: throw VocabularyError.invalidContent
        }
    }

    public func media(assetID: String, workspaceID: String) throws -> ReviewMaterialPreparedMedia? {
        try load(whereClause: "media_asset_id=?", value: assetID, workspaceID: workspaceID)
    }
    public func media(reference: ReviewMaterialMediaReference, workspaceID: String) throws -> ReviewMaterialPreparedMedia? {
        guard reference.isValid else { throw VocabularyError.invalidContent }
        let value = try load(whereClause: "digest=?", value: reference.digest, workspaceID: workspaceID)
        guard value == nil || value?.reference == reference else { throw VocabularyError.invalidContent }
        return value
    }
    private func load(whereClause: String, value: String, workspaceID: String) throws -> ReviewMaterialPreparedMedia? {
        try core.query(sql: "SELECT reference_json,bytes_base64 FROM notebook_review_media WHERE workspace_id=? AND " + whereClause,
            values: [.text(workspaceID), .text(value)]) { row in
                let reference = try core.decoder.decode(ReviewMaterialMediaReference.self, from: Data(DatabaseCore.columnText(statement: row, index: 0).utf8))
                guard reference.isValid, let bytes = Data(base64Encoded: DatabaseCore.columnText(statement: row, index: 1)) else { throw VocabularyError.invalidContent }
                let prepared = ReviewMaterialPreparedMedia(reference: reference, data: bytes)
                try Self.validate(prepared)
                return prepared
            }.first
    }

    public func insert(_ prepared: ReviewMaterialPreparedMedia, workspaceID: String, acknowledged: Bool = false) throws {
        try Self.validate(prepared)
        let reference = prepared.reference
        if let existing = try media(reference: reference, workspaceID: workspaceID) {
            guard existing == prepared else { throw VocabularyError.invalidContent }
            return
        }
        let id = LingroveNotebookCardMaterial.mediaAssetID(reference: reference, workspaceID: workspaceID)
        let now = nowIsoTimestamp(), installation = try WorkspaceSettingsStore(core: core).loadCloudSettings().installationId
        let asset = MediaAsset(mediaAssetId: id, workspaceId: workspaceID, mimeType: reference.mimeType,
            sizeBytes: Int64(reference.byteCount), sha256: reference.digest, sourceUrl: nil, createdAt: now,
            clientUpdatedAt: now, lastModifiedByReplicaId: mediaUploadWorkspaceReplicaId(workspaceId: workspaceID, installationId: installation),
            lastOperationId: UUID().uuidString.lowercased(), updatedAt: now, deletedAt: nil)
        try MediaAssetStore(core: core).upsertMediaAsset(workspaceId: workspaceID, mediaAsset: asset)
        try core.execute(sql: "INSERT INTO notebook_review_media(workspace_id,digest,media_asset_id,reference_json,bytes_base64,acknowledged) VALUES(?,?,?,?,?,?)",
            values: [.text(workspaceID), .text(reference.digest), .text(id), .text(try core.encodeJsonString(value: reference)),
                     .text(prepared.data.base64EncodedString()), .integer(acknowledged ? 1 : 0)])
    }

    /// Media goes first in a bounded v2 envelope. Its exact digest ACK is independent of Card
    /// ACKs; an old server response cannot discard a pending recording by ignoring this field.
    public func pending(workspaceID: String) throws -> [ReviewMaterialPreparedMedia] {
        let ids = try core.query(sql: "SELECT media_asset_id FROM notebook_review_media WHERE workspace_id=? AND acknowledged=0 ORDER BY digest LIMIT 1",
            values: [.text(workspaceID)]) { DatabaseCore.columnText(statement: $0, index: 0) }
        return try ids.compactMap { try media(assetID: $0, workspaceID: workspaceID) }
    }
    public func acknowledge(_ digests: [String], workspaceID: String) throws {
        for digest in digests {
            guard try core.execute(sql: "UPDATE notebook_review_media SET acknowledged=1 WHERE workspace_id=? AND digest=?",
                values: [.text(workspaceID), .text(digest)]) == 1 else { throw LingroveNotebookNetworkError.invalidReply }
        }
    }
}
