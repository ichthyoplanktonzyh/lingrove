/// Schema 33 extends frozen uploads without rewriting existing direct bytes or
/// digests. Temporary confirmation pages cascade with their batch; the compact
/// completed manifest survives it and contains no corpus body or UUID array.
public enum LingroveNotebookStagedUploadSchema {
    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_staged_uploads (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_upload_batches(workspace_id) ON DELETE CASCADE,
            frozen_sha256 TEXT NOT NULL CHECK(length(frozen_sha256)=64),
            descriptor_sha256 TEXT NOT NULL CHECK(length(descriptor_sha256)=64),
            manifest_json TEXT CHECK(manifest_json IS NULL OR length(CAST(manifest_json AS BLOB))<=16384),
            manifest_sha256 TEXT,
            CHECK((manifest_json IS NULL AND manifest_sha256 IS NULL) OR
              (manifest_json IS NOT NULL AND manifest_sha256 IS NOT NULL AND length(manifest_sha256)=64))
        );
        CREATE TABLE IF NOT EXISTS notebook_upload_confirmation_pages (
            workspace_id TEXT NOT NULL REFERENCES notebook_staged_uploads(workspace_id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 244),
            page_json TEXT NOT NULL CHECK(length(CAST(page_json AS BLOB))<=262144),
            page_sha256 TEXT NOT NULL CHECK(length(page_sha256)=64),
            PRIMARY KEY(workspace_id,ordinal)
        );
        CREATE TABLE IF NOT EXISTS notebook_staged_upload_outcomes (
            workspace_id TEXT NOT NULL REFERENCES notebook_remote_state(workspace_id) ON DELETE CASCADE,
            group_id TEXT NOT NULL,
            local_notebook_id TEXT NOT NULL,
            owner_user_id TEXT NOT NULL,
            remote_notebook_id TEXT NOT NULL,
            replica_id TEXT NOT NULL,
            body_sha256 TEXT NOT NULL CHECK(length(body_sha256)=64),
            manifest_json TEXT NOT NULL CHECK(length(CAST(manifest_json AS BLOB))<=16384),
            manifest_sha256 TEXT NOT NULL CHECK(length(manifest_sha256)=64),
            created_at TEXT NOT NULL,
            PRIMARY KEY(workspace_id,group_id)
        );
        """
    public static let addTransportSQL = """
        ALTER TABLE notebook_upload_batches ADD COLUMN transport_kind TEXT NOT NULL DEFAULT 'direct' CHECK(transport_kind IN ('direct','staged'));
        """
    public static let resetSQL = """
        DROP TABLE IF EXISTS notebook_upload_confirmation_pages;
        DROP TABLE IF EXISTS notebook_staged_uploads;
        DROP TABLE IF EXISTS notebook_staged_upload_outcomes;
        """
}
