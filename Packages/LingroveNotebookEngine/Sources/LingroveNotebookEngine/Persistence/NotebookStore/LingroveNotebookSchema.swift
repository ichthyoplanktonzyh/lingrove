import LingroveNotebookPersistenceCodec
import LingroveNotebook

/// Notebook tables extend the existing app database and never replace Cards or its scheduler.
/// All keys and relationships include workspace ownership; codec IDs remain their original text
/// (including composite child IDs), while physical table names have a notebook-only prefix.
public enum LingroveNotebookSchema {
    public static func table(_ entity: VocabularyPersistenceEntity) -> String { "notebook_" + entity.rawValue }

    public static var createSQL: String {
        var statements = ["""
        CREATE TABLE IF NOT EXISTS notebook_state (
            workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
            notebook_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision >= 0),
            has_templates INTEGER NOT NULL CHECK(has_templates IN (0,1)),
            updated_at TEXT NOT NULL
        );
        """]
        for entity in VocabularyPersistenceEntity.allCases {
            let parent = entity.parent.map {
                ",FOREIGN KEY(workspace_id,parent_id) REFERENCES \(table($0))(workspace_id,id) DEFERRABLE INITIALLY DEFERRED"
            } ?? ",CHECK(parent_id IS NULL)"
            let indexes = entity.indexKeys.map {
                ",\($0.rawValue) TEXT" + (nullableIndex($0, in: entity) ? "" : " NOT NULL")
            }.joined()
            let parentColumn = entity.parent == nil ? "TEXT" : "TEXT NOT NULL"
            statements.append("""
            CREATE TABLE IF NOT EXISTS \(table(entity)) (
                workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
                id TEXT NOT NULL,
                parent_id \(parentColumn),
                position INTEGER NOT NULL CHECK(position >= 0),
                payload_json TEXT NOT NULL\(indexes),
                PRIMARY KEY(workspace_id,id)\(parent)\(constraints(entity))
            );
            CREATE INDEX IF NOT EXISTS \(table(entity))_owner ON \(table(entity))(workspace_id,parent_id,position);
            """)
        }
        statements.append("""
        CREATE UNIQUE INDEX IF NOT EXISTS notebook_entries_lookup ON notebook_entries(workspace_id,lookup_key);
        CREATE UNIQUE INDEX IF NOT EXISTS notebook_preferred_label ON notebook_meaning_labels(workspace_id,parent_id,language) WHERE preferred='yes';
        CREATE TABLE IF NOT EXISTS notebook_pending_transactions (
            operation_id TEXT PRIMARY KEY NOT NULL,
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            notebook_id TEXT NOT NULL,
            base_revision INTEGER NOT NULL CHECK(base_revision >= 0),
            revision INTEGER NOT NULL CHECK(revision > base_revision),
            has_templates INTEGER NOT NULL CHECK(has_templates IN (0,1)),
            has_public_change INTEGER NOT NULL DEFAULT 1 CHECK(has_public_change IN (0,1)),
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS notebook_pending_rows (
            operation_id TEXT NOT NULL REFERENCES notebook_pending_transactions(operation_id) ON DELETE CASCADE,
            position INTEGER NOT NULL CHECK(position >= 0),
            entity TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            action TEXT NOT NULL CHECK(action IN ('upsert','delete')),
            parent_id TEXT,
            entity_position INTEGER NOT NULL CHECK(entity_position >= 0),
            payload_json TEXT,
            indexes_json TEXT NOT NULL,
            PRIMARY KEY(operation_id,position)
        );
        CREATE INDEX IF NOT EXISTS notebook_pending_workspace ON notebook_pending_transactions(workspace_id,revision);
        """)
        statements.append(mediaSQL)
        statements.append(LingroveNotebookCardLinkSchema.createSQL)
        statements.append(LingroveNotebookReviewSchema.createSQL)
        statements.append(LingroveNotebookWindowSchema.createSQL)
        statements.append(LingroveNotebookSyncSchema.createSQL)
        statements.append(LingroveNotebookUploadSchema.createSQL)
        statements.append(LingroveNotebookTerminalSchema.createSQL)
        statements.append(LingroveNotebookStagedUploadSchema.createSQL)
        statements.append(LingroveNotebookUploadClosureSchema.createSQL)
        statements.append(LingroveNotebookRetrySchema.createSQL)
        statements.append(LingroveNotebookConflictStore.createSQL)
        statements.append(LingroveNotebookAccountStore.createSQL)
        statements.append(LingroveNotebookMediaQueueSchema.createSQL)
        return statements.joined(separator: "\n")
    }

    /// Original notebook PNGs use the existing media registry/cache, with an explicit owner
    /// instead of pretending that the image belongs to a Card. Asset IDs stay stable on retry.
    public static let mediaSQL = """
        CREATE TABLE IF NOT EXISTS notebook_media_assets (
            workspace_id TEXT NOT NULL REFERENCES notebook_state(workspace_id) ON DELETE CASCADE,
            digest TEXT NOT NULL REFERENCES media_blob_cache(sha256) ON DELETE RESTRICT CHECK(length(digest)=64 AND digest NOT GLOB '*[^0-9a-f]*'),
            media_asset_id TEXT NOT NULL,
            width INTEGER NOT NULL CHECK(width BETWEEN 1 AND \(VocabularyContentPolicy.maximumDimension)),
            height INTEGER NOT NULL CHECK(height BETWEEN 1 AND \(VocabularyContentPolicy.maximumDimension)),
            byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND \(VocabularyContentPolicy.maximumImageBytes)),
            PRIMARY KEY(workspace_id,digest),
            UNIQUE(workspace_id,media_asset_id),
            FOREIGN KEY(workspace_id,media_asset_id) REFERENCES media_assets(workspace_id,media_asset_id) DEFERRABLE INITIALLY DEFERRED
        );
        """

    public static var resetSQL: String {
        LingroveNotebookMediaQueueSchema.resetSQL + "\n" + LingroveNotebookAccountStore.resetSQL + "\n" + LingroveNotebookConflictStore.resetSQL + "\n" + LingroveNotebookRetrySchema.resetSQL + "\n" + LingroveNotebookUploadClosureSchema.resetSQL + "\n" + LingroveNotebookStagedUploadSchema.resetSQL + "\n" + LingroveNotebookTerminalSchema.resetSQL + "\n" + LingroveNotebookUploadSchema.resetSQL + "\n" + LingroveNotebookSyncSchema.resetSQL + "\n" + LingroveNotebookWindowSchema.resetSQL + "\n" + LingroveNotebookReviewSchema.resetSQL + "\n" + LingroveNotebookCardLinkSchema.resetSQL + "\n" +
        (["DROP TABLE IF EXISTS notebook_media_assets;", "DROP TABLE IF EXISTS notebook_pending_rows;", "DROP TABLE IF EXISTS notebook_pending_transactions;"] +
            VocabularyPersistenceEntity.allCases.reversed().map { "DROP TABLE IF EXISTS \(table($0));" } +
            ["DROP TABLE IF EXISTS notebook_state;"]).joined(separator: "\n")
    }

    private static func foreignKey(_ key: String, _ target: VocabularyPersistenceEntity) -> String {
        ",FOREIGN KEY(workspace_id,\(key)) REFERENCES \(table(target))(workspace_id,id) DEFERRABLE INITIALLY DEFERRED"
    }

    /// Nullability belongs to the domain, rather than SQLite's permissive composite-FK rules:
    /// a missing required index must not silently bypass ownership checks.
    private static func nullableIndex(_ key: VocabularyPersistenceIndex, in entity: VocabularyPersistenceEntity) -> Bool {
        switch (entity, key) {
        case (.usages, .senseID), (.meaningMappings, .patternID), (.categories, .frameworkID), (.categories, .catalogKey): true
        default: false
        }
    }

    private static func constraints(_ entity: VocabularyPersistenceEntity) -> String {
        switch entity {
        case .usages:
            return foreignKey("occurrence_id", .occurrences) + foreignKey("sense_id", .senses) +
                ",CHECK(occurrence_id IS NOT NULL),CHECK(status IN ('candidate','accepted','rejected'))"
        case .collections:
            return foreignKey("sense_id", .senses) + ",UNIQUE(workspace_id,sense_id),CHECK(sense_id IS NOT NULL)"
        case .collectionInterpretations:
            return foreignKey("usage_id", .usages) + ",UNIQUE(workspace_id,parent_id,usage_id)"
        case .meaningNodes: return ",CHECK(kind IN ('concept','function'))"
        case .meaningLabels: return ",CHECK(preferred IN ('yes','no'))"
        case .usagePatterns: return ",UNIQUE(workspace_id,id,parent_id)"
        case .meaningMappings:
            return foreignKey("meaning_id", .meaningNodes) +
                ",FOREIGN KEY(workspace_id,pattern_id,parent_id) REFERENCES notebook_usage_patterns(workspace_id,id,parent_id) DEFERRABLE INITIALLY DEFERRED" +
                ",CHECK(relation IN ('expressesContent','realizesFunction'))"
        case .mappingRoles: return foreignKey("role_id", .meaningRoles) + foreignKey("slot_id", .patternSlots)
        case .mappingEvidence: return foreignKey("usage_id", .usages)
        case .meaningRelations:
            return foreignKey("target_id", .meaningNodes) + ",CHECK(parent_id <> target_id),CHECK(relation IN ('narrower','opposite','related'))"
        case .cueTargets: return foreignKey("meaning_id", .meaningNodes) + ",UNIQUE(workspace_id,parent_id,meaning_id)"
        case .classificationFrameworks: return ",UNIQUE(workspace_id,catalog_key)"
        case .categories:
            return foreignKey("framework_id", .classificationFrameworks) +
                ",UNIQUE(workspace_id,framework_id,catalog_key),CHECK(axis IN ('content','function'))"
        case .categoryParents:
            return foreignKey("category_id", .categories) + foreignKey("parent_category_id", .categories) +
                ",UNIQUE(workspace_id,category_id,parent_category_id),CHECK(category_id <> parent_category_id)"
        case .categoryMemberships:
            return foreignKey("meaning_id", .meaningNodes) + foreignKey("category_id", .categories) + ",UNIQUE(workspace_id,meaning_id,category_id)"
        default: return ""
        }
    }
}
