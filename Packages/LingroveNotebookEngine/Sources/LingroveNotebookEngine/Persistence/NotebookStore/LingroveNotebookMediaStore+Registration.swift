import Foundation
import LingroveNotebook
import SQLite3

/// One held writer transaction owns these observations. They never outlive the transaction
/// or hide later workspace/registry changes behind a process cache.
struct NotebookImageRegistration {
    let assetID: String?
    let trustedMetadata: Bool
}

extension LingroveNotebookMediaStore {
    /// Recheck the entire certificate's media set with one indexed join. Unchanged image-rich
    /// corpora used to issue three registry queries per image on every unrelated text save.
    /// Missing/stale blob metadata remains repairable through the existing PNG read path.
    func registrations(_ references: Set<VocabularyImageReference>, workspace: String) throws -> [String: NotebookImageRegistration] {
        var byDigest: [String: VocabularyImageReference] = [:]
        for reference in references {
            guard VocabularyContentPolicy.valid(reference),
                  byDigest[reference.digest] == nil || byDigest[reference.digest] == reference else { throw VocabularyError.invalidContent }
            byDigest[reference.digest] = reference
        }
        guard let encoded = String(data: try JSONEncoder().encode(byDigest.keys.sorted()), encoding: .utf8) else {
            throw VocabularyError.invalidArchive
        }
        let rows = try core.query(sql: """
            SELECT input.value,n.media_asset_id,n.width,n.height,n.byte_count,
                   a.deleted_at,a.sha256,a.mime_type,a.size_bytes,c.mime_type,c.size_bytes,c.local_relative_path
            FROM json_each(?) input
            LEFT JOIN notebook_media_assets n ON n.workspace_id=? AND n.digest=input.value
            LEFT JOIN media_assets a ON a.workspace_id=n.workspace_id AND a.media_asset_id=n.media_asset_id
            LEFT JOIN media_blob_cache c ON c.sha256=input.value
            """, values: [.text(encoded), .text(workspace)]) { row -> (String, NotebookImageRegistration) in
            let digest = DatabaseCore.columnText(statement: row, index: 0)
            guard let reference = byDigest[digest] else { throw VocabularyError.invalidContent }
            if sqlite3_column_type(row, 1) == SQLITE_NULL { return (digest, .init(assetID: nil, trustedMetadata: false)) }
            let id = DatabaseCore.columnText(statement: row, index: 1)
            guard UUID(uuidString: id) != nil,
                  (2...4).allSatisfy({ sqlite3_column_type(row, Int32($0)) == SQLITE_INTEGER }),
                  sqlite3_column_int64(row, 2) == reference.width, sqlite3_column_int64(row, 3) == reference.height,
                  sqlite3_column_int64(row, 4) == reference.byteCount else { throw VocabularyError.invalidContent }
            let expectedPath = try mediaBlobCacheRelativePath(sha256: digest)
            let trusted = sqlite3_column_type(row, 5) == SQLITE_NULL &&
                DatabaseCore.columnText(statement: row, index: 6) == digest &&
                DatabaseCore.columnText(statement: row, index: 7) == "image/png" &&
                sqlite3_column_int64(row, 8) == reference.byteCount &&
                DatabaseCore.columnText(statement: row, index: 9) == "image/png" &&
                sqlite3_column_int64(row, 10) == reference.byteCount &&
                DatabaseCore.columnText(statement: row, index: 11) == expectedPath
            return (digest, .init(assetID: id, trustedMetadata: trusted))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }
}
