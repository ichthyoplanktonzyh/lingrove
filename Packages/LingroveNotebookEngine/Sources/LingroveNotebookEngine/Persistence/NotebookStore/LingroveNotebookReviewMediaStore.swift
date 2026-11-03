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

    /// Caller already owns its saved-source writer transaction. All supplied data is checked
    /// before the first row is inserted; a subsequent failure still rolls back every row.
    public func register(plan: ReviewMaterialPlan?, source: LingroveNotebookCardSource,
                         snapshot: LingroveNotebookSnapshot, supplied: [ReviewMaterialPreparedMedia]) throws {
        guard let plan else {
            guard supplied.isEmpty else { throw VocabularyError.invalidContent }; return
        }
        try ReviewMaterialResolver.validate(plan)
        var references = Set(plan.layout.customContent.compactMap { block -> ReviewMaterialMediaReference? in
            if case let .image(image, _) = block.content { .init(image: image) } else { nil }
        })
        references.formUnion(plan.audio.values.map(\.reference))
        if let selection = LingroveNotebookCardMaterial.resolvedSelection(source: source, snapshot: snapshot),
           let entry = snapshot.document.entries.first(where: { $0.id == selection.entryID }),
           let sense = entry.senses.first(where: { $0.id == selection.senseID }),
           let resolved = try? LingroveNotebookCardMaterial.mediaReferences(entry: entry, sense: sense, plan: plan) {
            references.formUnion(resolved)
        }
        guard references.reduce(0, { $0 + $1.byteCount }) <= 16 * 1024 * 1024,
              Set(supplied.map { $0.reference.digest }).count == supplied.count,
              supplied.count <= 128, supplied.reduce(0, { $0 + $1.reference.byteCount }) <= 16 * 1024 * 1024 else { throw VocabularyError.invalidContent }
        for prepared in supplied { try Self.validate(prepared) }
        let byDigest = Dictionary(uniqueKeysWithValues: supplied.map { ($0.reference.digest, $0) })
        for reference in references.sorted(by: { $0.digest < $1.digest }) {
            try Task.checkCancellation()
            if let prepared = byDigest[reference.digest] {
                try insert(prepared, workspaceID: source.workspaceId)
            } else if let existing = try media(reference: reference, workspaceID: source.workspaceId) {
                guard existing.reference == reference else { throw VocabularyError.invalidContent }
            } else if let image = reference.image {
                // Existing corpus ownership authorizes reuse. A foreign cache hit alone does not.
                let bytes = try LingroveNotebookMediaStore(core: core).ownedImage(image, workspaceId: source.workspaceId)
                try insert(.init(reference: reference, data: bytes), workspaceID: source.workspaceId)
            } else { throw VocabularyError.invalidContent }
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
