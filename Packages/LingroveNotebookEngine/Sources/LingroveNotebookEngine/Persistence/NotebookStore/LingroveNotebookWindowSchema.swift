/// Incoming bytes share the existing app database, but own no editable notebook
/// rows, legacy outbox entries or applied cursor. A random binding generation is
/// rotated by SQLite itself so late callbacks cannot survive an account/workspace
/// round trip, even when the final settings values look identical (the ABA case).
public enum LingroveNotebookWindowSchema {
    public static var createSQL: String {
        var sql = """
        CREATE TABLE IF NOT EXISTS notebook_window_binding (
            settings_id INTEGER PRIMARY KEY CHECK(settings_id=1),
            generation TEXT NOT NULL UNIQUE CHECK(length(generation)=32)
        );
        INSERT OR IGNORE INTO notebook_window_binding(settings_id,generation) VALUES(1,lower(hex(randomblob(16))));
        CREATE TABLE IF NOT EXISTS notebook_download_windows (
            binding_generation TEXT NOT NULL REFERENCES notebook_window_binding(generation) ON DELETE CASCADE,
            workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
            owner_user_id TEXT NOT NULL,
            notebook_id TEXT NOT NULL,
            replica_id TEXT NOT NULL,
            window_id TEXT NOT NULL,
            manifest_sha256 TEXT NOT NULL CHECK(length(manifest_sha256)=64),
            manifest_json TEXT NOT NULL,
            expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms>=0),
            PRIMARY KEY(binding_generation,workspace_id,owner_user_id,notebook_id,replica_id,window_id)
        );
        CREATE TABLE IF NOT EXISTS notebook_download_pages (
            binding_generation TEXT NOT NULL,
            workspace_id TEXT NOT NULL,
            owner_user_id TEXT NOT NULL,
            notebook_id TEXT NOT NULL,
            replica_id TEXT NOT NULL,
            window_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL CHECK(ordinal>=0),
            body_base64 TEXT NOT NULL,
            sha256 TEXT NOT NULL CHECK(length(sha256)=64),
            byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND 262144),
            PRIMARY KEY(binding_generation,workspace_id,owner_user_id,notebook_id,replica_id,window_id,ordinal),
            FOREIGN KEY(binding_generation,workspace_id,owner_user_id,notebook_id,replica_id,window_id)
              REFERENCES notebook_download_windows(binding_generation,workspace_id,owner_user_id,notebook_id,replica_id,window_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS notebook_download_expiry ON notebook_download_windows(expires_at_ms);
        """
        let rotate = """
            DELETE FROM notebook_window_binding;
            INSERT INTO notebook_window_binding(settings_id,generation) VALUES(1,lower(hex(randomblob(16))));
            """
        sql += "\n" + """
        CREATE TRIGGER IF NOT EXISTS notebook_window_cloud_insert AFTER INSERT ON app_local_settings BEGIN \(rotate) END;
        CREATE TRIGGER IF NOT EXISTS notebook_window_cloud_delete AFTER DELETE ON app_local_settings BEGIN \(rotate) END;
        CREATE TRIGGER IF NOT EXISTS notebook_window_cloud_update
        AFTER UPDATE OF installation_id,cloud_state,linked_user_id,linked_workspace_id,active_workspace_id ON app_local_settings
        WHEN OLD.installation_id IS NOT NEW.installation_id OR OLD.cloud_state IS NOT NEW.cloud_state
          OR OLD.linked_user_id IS NOT NEW.linked_user_id OR OLD.linked_workspace_id IS NOT NEW.linked_workspace_id
          OR OLD.active_workspace_id IS NOT NEW.active_workspace_id
        BEGIN \(rotate) END;
        CREATE TRIGGER IF NOT EXISTS notebook_window_workspace_delete AFTER DELETE ON workspaces BEGIN \(rotate) END;
        """
        return sql
    }
    public static let resetSQL = """
        DROP TRIGGER IF EXISTS notebook_window_cloud_insert;
        DROP TRIGGER IF EXISTS notebook_window_cloud_delete;
        DROP TRIGGER IF EXISTS notebook_window_cloud_update;
        DROP TRIGGER IF EXISTS notebook_window_workspace_delete;
        DROP TABLE IF EXISTS notebook_download_pages;
        DROP TABLE IF EXISTS notebook_download_windows;
        DROP TABLE IF EXISTS notebook_window_binding;
        """
}
