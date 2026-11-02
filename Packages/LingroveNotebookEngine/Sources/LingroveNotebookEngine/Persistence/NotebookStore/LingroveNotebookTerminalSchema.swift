/// Cancellation intent and negative confirmations belong to the frozen batch,
/// not to the editable document. A separate child table extends schema 31
/// without rewriting its immutable bytes or existing positive receipts.
public enum LingroveNotebookTerminalSchema {
    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_upload_terminal_state (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_upload_batches(workspace_id) ON DELETE CASCADE,
            frozen_sha256 TEXT NOT NULL CHECK(length(frozen_sha256)=64),
            cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1)),
            rejection_json TEXT,
            rejection_sha256 TEXT,
            CHECK((rejection_json IS NULL AND rejection_sha256 IS NULL) OR
              (rejection_json IS NOT NULL AND rejection_sha256 IS NOT NULL AND length(rejection_sha256)=64))
        );
        CREATE TABLE IF NOT EXISTS notebook_upload_rejections (
            workspace_id TEXT NOT NULL REFERENCES notebook_remote_state(workspace_id) ON DELETE CASCADE,
            group_id TEXT NOT NULL,
            local_notebook_id TEXT NOT NULL,
            owner_user_id TEXT NOT NULL,
            remote_notebook_id TEXT NOT NULL,
            replica_id TEXT NOT NULL,
            body_sha256 TEXT NOT NULL CHECK(length(body_sha256)=64),
            rejection_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(workspace_id,group_id)
        );
        """
    // Only the versioned migration may backfill missing state. Running this on
    // ordinary reopen would hide a damaged/deleted cancellation record.
    public static let migrateFrom31SQL = createSQL + "\n" + """
        INSERT INTO notebook_upload_terminal_state(workspace_id,frozen_sha256,cancel_requested)
        SELECT workspace_id,frozen_sha256,0 FROM notebook_upload_batches;
        """
    public static let resetSQL = """
        DROP TABLE IF EXISTS notebook_upload_terminal_state;
        DROP TABLE IF EXISTS notebook_upload_rejections;
        """
}
