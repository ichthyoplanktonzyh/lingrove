/// One immutable in-flight public group per notebook. A receipt alone does not
/// delete it: the covering pull, document rebase, journal retirement and compact
/// receipt ledger commit together. Completed ledgers retain no corpus bodies.
public enum LingroveNotebookUploadSchema {
    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_upload_batches (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_remote_state(workspace_id) ON DELETE CASCADE,
            local_notebook_id TEXT NOT NULL,
            owner_user_id TEXT NOT NULL,
            remote_notebook_id TEXT NOT NULL,
            replica_id TEXT NOT NULL,
            base_sequence TEXT NOT NULL,
            local_revision INTEGER NOT NULL CHECK(local_revision>=0),
            request_json TEXT NOT NULL,
            target_json TEXT NOT NULL,
            coverage_json TEXT NOT NULL,
            transport_kind TEXT NOT NULL DEFAULT 'direct' CHECK(transport_kind IN ('direct','staged')),
            frozen_sha256 TEXT NOT NULL CHECK(length(frozen_sha256)=64),
            receipt_json TEXT,
            receipt_sha256 TEXT,
            CHECK((receipt_json IS NULL AND receipt_sha256 IS NULL) OR (receipt_json IS NOT NULL AND receipt_sha256 IS NOT NULL AND length(receipt_sha256)=64))
        );
        CREATE TABLE IF NOT EXISTS notebook_upload_receipts (
            workspace_id TEXT NOT NULL REFERENCES notebook_remote_state(workspace_id) ON DELETE CASCADE,
            group_id TEXT NOT NULL,
            local_notebook_id TEXT NOT NULL,
            owner_user_id TEXT NOT NULL,
            remote_notebook_id TEXT NOT NULL,
            replica_id TEXT NOT NULL,
            body_sha256 TEXT NOT NULL CHECK(length(body_sha256)=64),
            receipt_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(workspace_id,group_id)
        );
        """
    public static let resetSQL = """
        DROP TABLE IF EXISTS notebook_upload_batches;
        DROP TABLE IF EXISTS notebook_upload_receipts;
        """
}
