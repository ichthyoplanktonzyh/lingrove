import Foundation
import CryptoKit
import LingroveNotebook
import SQLite3

/// A durable certificate of the last completely checked canonical corpus. The writer owns
/// this derived metadata; no UI draft can create it. A raw/sync/schema/account change makes
/// its exact clock/version mismatch, forcing complete preparation before another local edit.
/// Media references are retained so a local text edit can still check every owned asset and
/// preserve the complete document pin set without decoding every unrelated content block.
struct NotebookEntryCheckpoint {
    let version: LingroveNotebookVersion
    let token: NotebookChangeToken
    let media: Set<VocabularyImageReference>

    static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_entry_checkpoint (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            notebook_id TEXT NOT NULL, revision INTEGER NOT NULL, generation TEXT NOT NULL,
            schema_version INTEGER NOT NULL, epoch TEXT NOT NULL, corpus_clock INTEGER NOT NULL,
            validation_version INTEGER NOT NULL,
            media_json TEXT NOT NULL CHECK(json_valid(media_json)), media_sha256 TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS notebook_sense_alias_owners ON notebook_senses(workspace_id,id)
            WHERE CASE WHEN json_valid(payload_json) THEN json_array_length(payload_json,'$.mergedFrom') ELSE 0 END>0;
        CREATE INDEX IF NOT EXISTS notebook_block_image_owners ON notebook_blocks(workspace_id,
            CASE WHEN json_valid(payload_json) THEN json_extract(payload_json,'$.content.image._0.digest') END);
        """

    // Bump when the meaning of the validation certificate changes, even without SQL DDL.
    private static let validationVersion = 2

    static func ensureInstalled(in core: DatabaseCore) throws {
        guard try core.scalarInt(sql: """
            SELECT COUNT(*) FROM sqlite_master
            WHERE name IN ('notebook_entry_checkpoint','notebook_sense_alias_owners',
                           'notebook_block_image_owners')
            """, values: []) != 3 else { return }
        try core.inTransaction { try core.executeScript(sql: createSQL, errorContext: "Create entry validation checkpoint") }
    }

    static func load(in core: DatabaseCore, version: LingroveNotebookVersion) throws -> Self? {
        let token = try core.notebookCacheToken()
        let records = try core.query(sql: """
            SELECT media_json,media_sha256 FROM notebook_entry_checkpoint
            WHERE workspace_id=? AND notebook_id=? AND revision=? AND generation=?
              AND schema_version=? AND epoch=? AND corpus_clock=? AND validation_version=?
            """, values: [.text(version.workspaceId), .text(version.notebookId.uuidString), .integer(Int64(version.revision)),
                .text(version.generation), .integer(Int64(token.schemaVersion)), .text(token.epoch), .integer(token.value),
                .integer(Int64(validationVersion))]) { row -> Self? in
            guard sqlite3_column_type(row, 0) == SQLITE_TEXT, sqlite3_column_type(row, 1) == SQLITE_TEXT else { return nil }
            let bytes = Data(DatabaseCore.columnText(statement: row, index: 0).utf8)
            guard digest(bytes) == DatabaseCore.columnText(statement: row, index: 1),
                  let media = try? JSONDecoder().decode(Set<VocabularyImageReference>.self, from: bytes) else { return nil }
            return Self(version: version, token: token, media: media)
        }
        return records.first.flatMap { $0 }
    }

    /// Called only while a full, checked state or an admitted local edit owns the writer
    /// transaction. Recording after canonical rows/header/journal keeps rollback atomic.
    static func record(in core: DatabaseCore, version: LingroveNotebookVersion,
                       media: Set<VocabularyImageReference>) throws {
        let token = try core.notebookCacheToken()
        let ordered = media.sorted {
            if $0.digest != $1.digest { return $0.digest < $1.digest }
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            return $0.byteCount < $1.byteCount
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(ordered)
        guard let payload = String(data: bytes, encoding: .utf8) else { throw VocabularyError.invalidArchive }
        try core.execute(sql: """
            INSERT INTO notebook_entry_checkpoint(workspace_id,notebook_id,revision,generation,
                schema_version,epoch,corpus_clock,validation_version,media_json,media_sha256)
            VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(workspace_id) DO UPDATE SET
              notebook_id=excluded.notebook_id,revision=excluded.revision,generation=excluded.generation,
              schema_version=excluded.schema_version,epoch=excluded.epoch,corpus_clock=excluded.corpus_clock,
              validation_version=excluded.validation_version,media_json=excluded.media_json,media_sha256=excluded.media_sha256
            WHERE notebook_id<>excluded.notebook_id OR revision<>excluded.revision OR generation<>excluded.generation
               OR schema_version<>excluded.schema_version OR epoch<>excluded.epoch OR corpus_clock<>excluded.corpus_clock
               OR validation_version<>excluded.validation_version OR media_json<>excluded.media_json OR media_sha256<>excluded.media_sha256
            """, values: [.text(version.workspaceId), .text(version.notebookId.uuidString), .integer(Int64(version.revision)),
                .text(version.generation), .integer(Int64(token.schemaVersion)), .text(token.epoch), .integer(token.value),
                .integer(Int64(validationVersion)), .text(payload), .text(digest(bytes))])
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
