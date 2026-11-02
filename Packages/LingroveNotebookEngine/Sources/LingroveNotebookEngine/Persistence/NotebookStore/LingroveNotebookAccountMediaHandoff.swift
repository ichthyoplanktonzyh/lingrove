import Foundation

/// Account adaptation for EXISTING Card media queues. Byte validation and HTTP
/// remain in the established transfer runner; original PNG notebook transport
/// belongs to its independent coordinator. Only explicitly copied Card asset
/// identities enter this method, never every digest in the shared cache.
extension MediaTransferStore {
    public func copyForNotebookAccountOwnership(source: String, target: String, assetIDs: [String: String]) throws {
        let assets = MediaAssetStore(core: core)
        for (old, new) in assetIDs {
            guard let asset = try assets.loadOptionalMediaAssetIncludingDeleted(workspaceId: source, mediaAssetId: old) else {
                throw LingroveNotebookAccountError.unavailableSource
            }
            let digest = asset.sha256
            let queue = try core.query(sql: "SELECT kind,sha256 FROM media_transfer_queue WHERE workspace_id=? AND media_asset_id=?",
                values: [.text(source), .text(old)]) { (DatabaseCore.columnText(statement: $0, index: 0), DatabaseCore.columnText(statement: $0, index: 1)) }
            guard queue.allSatisfy({ $0.1 == digest }) else { throw LingroveNotebookAccountError.unavailableSource }
            var kinds = Set(queue.map(\.0))
            if try loadOptionalBlobCacheEntry(sha256: digest) != nil { kinds.insert(MediaTransferKind.upload.rawValue) }
            guard !kinds.isEmpty else { throw LingroveNotebookAccountError.unavailableSource }
            for raw in kinds.sorted() {
                guard let kind = MediaTransferKind(rawValue: raw) else { throw LingroveNotebookAccountError.unavailableSource }
                if try core.scalarInt(sql: "SELECT EXISTS(SELECT 1 FROM media_transfer_queue WHERE workspace_id=? AND media_asset_id=? AND kind=?)",
                    values: [.text(target), .text(new), .text(raw)]) != 0 { continue }
                _ = try enqueueTransfer(request: .init(transferId: UUID().uuidString.lowercased(), workspaceId: target, mediaAssetId: new,
                    kind: kind, sha256: digest, mimeType: asset.mimeType, sizeBytes: asset.sizeBytes, createdAt: nowIsoTimestamp()))
            }
        }
    }
}
