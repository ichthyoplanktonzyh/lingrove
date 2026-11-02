import Foundation

/// Jobs retain expected metadata before any bytes exist. Pins name independent
/// consumers, so a cancelled transfer or frozen graph outlives a UI draft/save.
public enum LingroveNotebookMediaQueueSchema {
    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_media_jobs (
            job_id TEXT PRIMARY KEY NOT NULL,
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            owner_user_id TEXT NOT NULL, notebook_id TEXT NOT NULL, replica_id TEXT NOT NULL,
            binding_generation TEXT NOT NULL,
            digest TEXT NOT NULL CHECK(length(digest)=64 AND digest NOT GLOB '*[^0-9a-f]*'),
            width INTEGER NOT NULL CHECK(width BETWEEN 1 AND 1600),
            height INTEGER NOT NULL CHECK(height BETWEEN 1 AND 1600),
            byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND 4194304),
            direction TEXT NOT NULL CHECK(direction IN ('upload','download')),
            state TEXT NOT NULL CHECK(state IN ('queued','transferring','missing','failed','cancelled','ready')),
            remote_asset_id TEXT,
            attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0),
            revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),
            attempt_id TEXT, process_id TEXT, lease_until REAL, next_attempt_at REAL,
            error_code TEXT,
            UNIQUE(workspace_id,owner_user_id,notebook_id,digest,direction)
        );
        CREATE INDEX IF NOT EXISTS notebook_media_job_state ON notebook_media_jobs(workspace_id,state,next_attempt_at);
        CREATE TABLE IF NOT EXISTS notebook_media_pins (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            consumer_id TEXT NOT NULL, digest TEXT NOT NULL,
            PRIMARY KEY(workspace_id,consumer_id,digest)
        );
        CREATE TABLE IF NOT EXISTS notebook_media_releases (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            owner_user_id TEXT NOT NULL, notebook_id TEXT NOT NULL,
            digest TEXT NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL, byte_count INTEGER NOT NULL,
            PRIMARY KEY(workspace_id,owner_user_id,notebook_id,digest)
        );
        """
    public static let resetSQL = "DROP TABLE IF EXISTS notebook_media_releases; DROP TABLE IF EXISTS notebook_media_pins; DROP TABLE IF EXISTS notebook_media_jobs;"
}
