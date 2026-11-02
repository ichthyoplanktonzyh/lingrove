/// Confirmed remote state is durable across process/account reconnects, unlike
/// a download cache. Local book IDs remain unchanged; one explicitly trusted
/// remote binding belongs to the workspace's existing notebook. Account erasure
/// cascades through notebook_state and removes its private remainder too.
public enum LingroveNotebookSyncSchema {
    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_remote_state (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            local_notebook_id TEXT NOT NULL,
            owner_user_id TEXT NOT NULL,
            remote_notebook_id TEXT NOT NULL,
            replica_id TEXT NOT NULL,
            sequence TEXT NOT NULL,
            initialized INTEGER NOT NULL CHECK(initialized IN (0,1)),
            revision INTEGER NOT NULL CHECK(revision>0),
            last_manifest_sha256 TEXT NOT NULL CHECK(length(last_manifest_sha256)=64),
            private_state_json TEXT NOT NULL,
            record_count INTEGER NOT NULL CHECK(record_count>=0),
            state_sha256 TEXT NOT NULL CHECK(length(state_sha256)=64)
        );
        CREATE TABLE IF NOT EXISTS notebook_remote_records (
            workspace_id TEXT NOT NULL REFERENCES notebook_remote_state(workspace_id) ON DELETE CASCADE,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            record_json TEXT NOT NULL,
            PRIMARY KEY(workspace_id,entity_type,entity_id)
        );
        """
    public static let resetSQL = """
        DROP TABLE IF EXISTS notebook_remote_records;
        DROP TABLE IF EXISTS notebook_remote_state;
        """
}
