import Foundation

/// These tables extend the notebook transaction domain without changing Card or FSRS columns.
/// Historical source/Card IDs intentionally have no cascading entity FK: source retirement and
/// a Card's tombstone must not erase provenance or the other object's data. The writer validates
/// both live owners when a link is created. Workspace/account erase still removes the whole graph.
public enum LingroveNotebookCardLinkSchema {
    public static let operationColumns = "operation_id,workspace_id,installation_id,entity_type,entity_id,operation_type,payload_json,client_updated_at,created_at,attempt_count,last_error,is_initial_create,review_schedule_impact"

    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_card_links (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            link_id TEXT NOT NULL,
            notebook_id TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            sense_id TEXT NOT NULL,
            example_id TEXT,
            card_id TEXT NOT NULL,
            generated_content_json TEXT,
            source_revision INTEGER NOT NULL CHECK(source_revision >= 0),
            creation_fingerprint TEXT NOT NULL CHECK(length(creation_fingerprint)=64),
            revision INTEGER NOT NULL CHECK(revision > 0),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            allows_unavailable_material INTEGER NOT NULL DEFAULT 0 CHECK(allows_unavailable_material IN (0,1)),
            material_plan_json TEXT,
            PRIMARY KEY(workspace_id,link_id)
        );
        CREATE UNIQUE INDEX IF NOT EXISTS notebook_card_link_live_source_card
            ON notebook_card_links(workspace_id,notebook_id,sense_id,card_id)
            WHERE deleted_at IS NULL;
        CREATE INDEX IF NOT EXISTS notebook_card_link_card ON notebook_card_links(workspace_id,card_id);
        CREATE INDEX IF NOT EXISTS notebook_card_link_source ON notebook_card_links(workspace_id,notebook_id,sense_id);
        CREATE TABLE IF NOT EXISTS notebook_card_link_operations (
            operation_id TEXT PRIMARY KEY NOT NULL,
            workspace_id TEXT NOT NULL,
            link_id TEXT NOT NULL,
            base_revision INTEGER NOT NULL CHECK(base_revision >= 0),
            revision INTEGER NOT NULL CHECK(revision > base_revision),
            card_operation_id TEXT,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(workspace_id,link_id) REFERENCES notebook_card_links(workspace_id,link_id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS notebook_card_sync_holds (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            card_id TEXT NOT NULL,
            notebook_id TEXT NOT NULL,
            creation_operation_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(workspace_id,card_id)
        );
        CREATE TABLE IF NOT EXISTS notebook_held_card_operations (
            operation_id TEXT PRIMARY KEY NOT NULL,
            workspace_id TEXT NOT NULL,
            subject_card_id TEXT NOT NULL,
            installation_id TEXT NOT NULL,
            entity_type TEXT NOT NULL CHECK(entity_type IN ('card','review_event')),
            entity_id TEXT NOT NULL,
            operation_type TEXT NOT NULL CHECK(operation_type IN ('upsert','append')),
            payload_json TEXT NOT NULL,
            client_updated_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            is_initial_create INTEGER NOT NULL CHECK(is_initial_create IN (0,1)),
            review_schedule_impact INTEGER NOT NULL CHECK(review_schedule_impact IN (0,1)),
            FOREIGN KEY(workspace_id,subject_card_id) REFERENCES notebook_card_sync_holds(workspace_id,card_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS notebook_held_card_operation_owner ON notebook_held_card_operations(workspace_id,subject_card_id,created_at);
        CREATE VIEW IF NOT EXISTS notebook_local_pending_operations AS
            SELECT \(operationColumns) FROM outbox
            UNION ALL
            SELECT \(operationColumns) FROM notebook_held_card_operations;
        """

    public static let resetSQL = """
        DROP VIEW IF EXISTS notebook_local_pending_operations;
        DROP TABLE IF EXISTS notebook_held_card_operations;
        DROP TABLE IF EXISTS notebook_card_sync_holds;
        DROP TABLE IF EXISTS notebook_card_link_operations;
        DROP TABLE IF EXISTS notebook_card_links;
        """
}
