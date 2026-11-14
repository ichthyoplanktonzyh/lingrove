import Foundation
import LingroveNotebook

/// SQLite owns this disposable browsing projection. Triggers cover app, sync and raw row
/// writes alike; no caller has to remember a second tag save. Canonical collection payloads
/// remain the authority. Installation/rebuild is atomic and changes the schema fence.
enum NotebookTagIndex {
    static func ensureInstalled(in core: DatabaseCore) throws {
        let names = """
            'notebook_collection_tags','notebook_invalid_collection_tags','notebook_tags_insert',
            'notebook_tags_update','notebook_tags_delete','notebook_tags_by_collection'
            """
        guard try core.scalarInt(sql: "SELECT COUNT(*) FROM sqlite_master WHERE name IN (\(names))", values: []) != 6 else { return }
        try core.inTransaction {
            try core.executeScript(sql: """
                CREATE TABLE IF NOT EXISTS notebook_collection_tags(
                    workspace_id TEXT NOT NULL,collection_id TEXT NOT NULL,sense_id TEXT NOT NULL,tag TEXT NOT NULL,
                    PRIMARY KEY(workspace_id,tag,sense_id,collection_id));
                CREATE INDEX IF NOT EXISTS notebook_tags_by_collection ON notebook_collection_tags(workspace_id,collection_id);
                CREATE TABLE IF NOT EXISTS notebook_invalid_collection_tags(
                    workspace_id TEXT NOT NULL,collection_id TEXT NOT NULL,PRIMARY KEY(workspace_id,collection_id));
                DELETE FROM notebook_collection_tags;
                DELETE FROM notebook_invalid_collection_tags;
                \(insertRows(source: "notebook_collections"))
                DROP TRIGGER IF EXISTS notebook_tags_insert;
                DROP TRIGGER IF EXISTS notebook_tags_update;
                DROP TRIGGER IF EXISTS notebook_tags_delete;
                """, errorContext: "Rebuild notebook tag index")
            for event in ["INSERT", "UPDATE", "DELETE"] {
                let remove = event == "INSERT" ? "" : """
                    DELETE FROM notebook_collection_tags WHERE workspace_id=OLD.workspace_id AND collection_id=OLD.id;
                    DELETE FROM notebook_invalid_collection_tags WHERE workspace_id=OLD.workspace_id AND collection_id=OLD.id;
                    """
                let source = """
                    (SELECT NEW.workspace_id workspace_id,NEW.id id,NEW.sense_id sense_id,NEW.payload_json payload_json)
                    """
                let insert = event == "DELETE" ? "" : insertRows(source: source)
                try core.executeScript(sql: """
                    CREATE TRIGGER notebook_tags_\(event.lowercased()) AFTER \(event) ON notebook_collections BEGIN
                        \(remove)
                        \(insert)
                    END;
                    """, errorContext: "Maintain notebook tag index")
            }
        }
    }

    /// Corrupt raw payloads must remain readable as version metadata, while a tag request
    /// still fails rather than silently hiding them. Guard JSON functions during indexing.
    private static func insertRows(source: String) -> String {
        let safe = "CASE WHEN json_valid(c.payload_json) THEN c.payload_json ELSE '{}' END"
        return """
            INSERT OR IGNORE INTO notebook_collection_tags
                SELECT c.workspace_id,c.id,c.sense_id,tag.value FROM \(source) c,json_each(\(safe),'$.tags') tag
                WHERE tag.type='text';
            INSERT OR IGNORE INTO notebook_invalid_collection_tags
                SELECT c.workspace_id,c.id FROM \(source) c WHERE NOT json_valid(c.payload_json)
                  OR COALESCE(json_type(\(safe),'$.tags'),'array')<>'array'
                  OR EXISTS(SELECT 1 FROM json_each(\(safe),'$.tags') tag WHERE tag.type<>'text');
            """
    }

    /// Read-only hosts can open a pre-index database without upgrading it. Their slower
    /// canonical query remains available until a writable engine installs the projection.
    static func available(in core: DatabaseCore, workspace: String) throws -> Bool {
        guard try core.tableExists(name: "notebook_collection_tags") else { return false }
        guard try core.scalarInt(sql: "SELECT EXISTS(SELECT 1 FROM notebook_invalid_collection_tags WHERE workspace_id=?)",
            values: [.text(workspace)]) == 0 else { throw VocabularyError.invalidArchive }
        return true
    }
}
