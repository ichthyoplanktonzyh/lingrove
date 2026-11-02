import Foundation

/// Enrollment extends the existing notebook transaction domain. Exercise mappings identify
/// Cards that are controlled by participation; ordinary Cards (even ones with a source link)
/// remain independent. Card/source IDs are historical references, so removing either cannot
/// cascade into review history. Whole-workspace deletion still removes enrollment metadata.
public enum LingroveNotebookReviewSchema {
    public static let createSQL = """
        CREATE TABLE IF NOT EXISTS notebook_review_enrollments (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            enrollment_id TEXT NOT NULL,
            notebook_id TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            sense_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('active','paused','withdrawn')),
            revision INTEGER NOT NULL CHECK(revision > 0),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(workspace_id,enrollment_id),
            UNIQUE(workspace_id,notebook_id,sense_id)
        );
        CREATE TABLE IF NOT EXISTS notebook_review_exercises (
            workspace_id TEXT NOT NULL,
            enrollment_id TEXT NOT NULL,
            card_id TEXT NOT NULL,
            link_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(workspace_id,card_id),
            UNIQUE(workspace_id,link_id),
            FOREIGN KEY(workspace_id,enrollment_id) REFERENCES notebook_review_enrollments(workspace_id,enrollment_id) ON DELETE CASCADE,
            FOREIGN KEY(workspace_id,link_id) REFERENCES notebook_card_links(workspace_id,link_id)
        );
        CREATE INDEX IF NOT EXISTS notebook_review_exercise_owner ON notebook_review_exercises(workspace_id,enrollment_id);
        CREATE TABLE IF NOT EXISTS notebook_review_operations (
            operation_id TEXT PRIMARY KEY NOT NULL,
            workspace_id TEXT NOT NULL,
            enrollment_id TEXT NOT NULL,
            base_revision INTEGER NOT NULL CHECK(base_revision >= 0),
            revision INTEGER NOT NULL CHECK(revision > base_revision),
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(workspace_id,enrollment_id) REFERENCES notebook_review_enrollments(workspace_id,enrollment_id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS notebook_review_material_state (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            card_id TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('ready','retained','sourceMissing','exampleMissing')),
            PRIMARY KEY(workspace_id,card_id)
        );
        CREATE TABLE IF NOT EXISTS notebook_review_history_adoptions (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            operation_id TEXT NOT NULL, card_id TEXT NOT NULL, payload_json TEXT NOT NULL,
            pending INTEGER NOT NULL DEFAULT 1 CHECK(pending IN (0,1)),
            PRIMARY KEY(workspace_id,operation_id), UNIQUE(workspace_id,card_id)
        );
        CREATE TABLE IF NOT EXISTS notebook_review_material_confirmations (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            card_id TEXT NOT NULL,source_sequence TEXT NOT NULL,link_revision INTEGER NOT NULL,card_operation_id TEXT NOT NULL,
            PRIMARY KEY(workspace_id,card_id)
        );
        CREATE TABLE IF NOT EXISTS notebook_review_sync_state (
            workspace_id TEXT PRIMARY KEY REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            after_sequence INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS notebook_review_undo (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            undo_id TEXT NOT NULL, card_id TEXT NOT NULL, event_id TEXT NOT NULL,
            target_operation_id TEXT NOT NULL, previous_card_json TEXT NOT NULL,
            created_at TEXT NOT NULL, pending INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY(workspace_id,undo_id), UNIQUE(workspace_id,event_id)
        );
        CREATE TABLE IF NOT EXISTS notebook_review_schedule_heads (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            card_id TEXT NOT NULL,operation_id TEXT,PRIMARY KEY(workspace_id,card_id)
        );
        CREATE TABLE IF NOT EXISTS notebook_review_last_rating (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            card_id TEXT NOT NULL, event_id TEXT NOT NULL, operation_id TEXT NOT NULL,
            previous_card_json TEXT NOT NULL, PRIMARY KEY(workspace_id,card_id)
        );
        CREATE TABLE IF NOT EXISTS notebook_review_requests (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            request_id TEXT NOT NULL,
            fingerprint TEXT NOT NULL CHECK(length(fingerprint)=64),
            enrollment_ids_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(workspace_id,request_id)
        );
        """

    public static let resetSQL = """
        DROP TABLE IF EXISTS notebook_review_history_adoptions;
        DROP TABLE IF EXISTS notebook_review_schedule_heads;
        DROP TABLE IF EXISTS notebook_review_last_rating;
        DROP TABLE IF EXISTS notebook_review_undo;
        DROP TABLE IF EXISTS notebook_review_material_confirmations;
        DROP TABLE IF EXISTS notebook_review_sync_state;
        DROP TABLE IF EXISTS notebook_review_material_state;
        DROP TABLE IF EXISTS notebook_review_requests;
        DROP TABLE IF EXISTS notebook_review_operations;
        DROP TABLE IF EXISTS notebook_review_exercises;
        DROP TABLE IF EXISTS notebook_review_enrollments;
        """
}
