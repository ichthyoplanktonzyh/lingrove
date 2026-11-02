/// Schema 35 persists resume authorization for a particular cancellation of a
/// frozen staged ticket. Repeated Cancel advances the local revision and revokes
/// old authorization; neither value is a remote corpus version or wire field.
public enum LingroveNotebookRetrySchema {
    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_upload_retry_intents (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_upload_transport_state(workspace_id) ON DELETE CASCADE,
            frozen_sha256 TEXT NOT NULL CHECK(length(frozen_sha256)=64),
            group_id TEXT NOT NULL CHECK(length(group_id)=36),
            cancel_revision INTEGER NOT NULL CHECK(cancel_revision>=0),
            resume_revision INTEGER CHECK(resume_revision>0 AND resume_revision<=cancel_revision)
        );
        """
    public static let migrateFrom34SQL = createSQL + "\n" + """
        INSERT INTO notebook_upload_retry_intents(workspace_id,frozen_sha256,group_id,cancel_revision)
        SELECT s.workspace_id,s.frozen_sha256,json_extract(u.request_json,'$.groupId'),t.cancel_requested
        FROM notebook_upload_transport_state s JOIN notebook_upload_batches u USING(workspace_id)
        JOIN notebook_upload_terminal_state t USING(workspace_id);
        UPDATE notebook_completed_upload_closures SET cancel_revision=cancel_requested;
        """
    public static let addCompletedRevisionSQL = "ALTER TABLE notebook_completed_upload_closures ADD COLUMN cancel_revision INTEGER NOT NULL DEFAULT 0 CHECK(cancel_revision>=0);"
    public static let resetSQL = "DROP TABLE IF EXISTS notebook_upload_retry_intents;"
}
