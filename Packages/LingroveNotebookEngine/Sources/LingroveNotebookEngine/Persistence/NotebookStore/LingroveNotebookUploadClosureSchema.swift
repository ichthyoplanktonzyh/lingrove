/// Schema 34 records a transport closure without fabricating a corpus decision.
/// Every staged batch has one required child row, including before any closure;
/// only this versioned migration may backfill old schema 33 rows. Completed
/// closures retain compact identity metadata and a user-cancellation retry gate.
public enum LingroveNotebookUploadClosureSchema {
    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_upload_transport_state (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_staged_uploads(workspace_id) ON DELETE CASCADE,
            frozen_sha256 TEXT NOT NULL CHECK(length(frozen_sha256)=64),
            closure_json TEXT CHECK(closure_json IS NULL OR length(CAST(closure_json AS BLOB))<=16384),
            closure_sha256 TEXT,
            CHECK((closure_json IS NULL AND closure_sha256 IS NULL) OR
              (closure_json IS NOT NULL AND closure_sha256 IS NOT NULL AND length(closure_sha256)=64))
        );
        CREATE TABLE IF NOT EXISTS notebook_completed_upload_closures (
            workspace_id TEXT NOT NULL REFERENCES notebook_remote_state(workspace_id) ON DELETE CASCADE,
            group_id TEXT NOT NULL,
            local_notebook_id TEXT NOT NULL,
            owner_user_id TEXT NOT NULL,
            remote_notebook_id TEXT NOT NULL,
            replica_id TEXT NOT NULL,
            body_sha256 TEXT NOT NULL CHECK(length(body_sha256)=64),
            closure_json TEXT NOT NULL CHECK(length(CAST(closure_json AS BLOB))<=16384),
            closure_sha256 TEXT NOT NULL CHECK(length(closure_sha256)=64),
            blocked_journal_revision INTEGER NOT NULL CHECK(blocked_journal_revision>=0),
            retry_blocked INTEGER NOT NULL CHECK(retry_blocked IN (0,1)),
            cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1) AND retry_blocked<=cancel_requested),
            cancel_revision INTEGER NOT NULL DEFAULT 0 CHECK(cancel_revision>=0),
            created_at TEXT NOT NULL,
            PRIMARY KEY(workspace_id,group_id)
        );
        """
    public static let migrateFrom33SQL = createSQL + "\n" + """
        INSERT INTO notebook_upload_transport_state(workspace_id,frozen_sha256)
        SELECT workspace_id,frozen_sha256 FROM notebook_staged_uploads;
        """
    public static let addPublicChangeSQL = """
        ALTER TABLE notebook_pending_transactions ADD COLUMN has_public_change INTEGER NOT NULL DEFAULT 1 CHECK(has_public_change IN (0,1));
        """
    public static let resetSQL = """
        DROP TABLE IF EXISTS notebook_upload_transport_state;
        DROP TABLE IF EXISTS notebook_completed_upload_closures;
        """
}
