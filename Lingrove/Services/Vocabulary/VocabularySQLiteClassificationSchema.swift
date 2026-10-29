import Foundation

/// Additive schema evolution runs under the database's existing file lock and one transaction.
/// No evidence, receipt or revision row is rewritten by a schema-only upgrade; failure rolls back
/// both the new tables and user_version so another launch can safely retry.
nonisolated enum VocabularySQLiteClassificationSchema {
    static let tables: [VocabularyDatabaseRecord.Table] = [
        .classificationFrameworks, .categories, .categoryParents, .categoryMemberships, .categoryOverrides
    ]

    static func columns(_ table: VocabularyDatabaseRecord.Table) -> String {
        let deferred = " DEFERRABLE INITIALLY DEFERRED"
        switch table {
        case .classificationFrameworks: return ",catalog_key TEXT NOT NULL UNIQUE"
        case .categories:
            return ",framework_id TEXT REFERENCES classification_frameworks(id)" + deferred +
                ",catalog_key TEXT,axis TEXT NOT NULL CHECK(axis IN ('content','function')),UNIQUE(framework_id,catalog_key)"
        case .categoryParents:
            return ",category_id TEXT NOT NULL REFERENCES categories(id)" + deferred +
                ",parent_category_id TEXT NOT NULL REFERENCES categories(id)" + deferred +
                ",UNIQUE(category_id,parent_category_id),CHECK(category_id<>parent_category_id)"
        case .categoryMemberships:
            return ",meaning_id TEXT NOT NULL REFERENCES meaning_nodes(id)" + deferred +
                ",category_id TEXT NOT NULL REFERENCES categories(id)" + deferred + ",UNIQUE(meaning_id,category_id)"
        default: return ""
        }
    }

    static func createIndexes(_ connection: VocabularySQLiteConnection) throws {
        try connection.execute("CREATE INDEX category_parents_parent ON category_parents(parent_category_id)")
        try connection.execute("CREATE INDEX category_memberships_category ON category_memberships(category_id,meaning_id)")
    }

    static func migrate(_ connection: VocabularySQLiteConnection) throws {
        try connection.transaction(write: true) {
            for table in tables {
                let parent = table.parent.map { "TEXT NOT NULL REFERENCES " + $0.rawValue +
                    "(id) DEFERRABLE INITIALLY DEFERRED" } ?? "TEXT CHECK(parent_id IS NULL)"
                try connection.execute("CREATE TABLE " + table.rawValue + " (id TEXT PRIMARY KEY NOT NULL,parent_id " + parent +
                    ",position INTEGER NOT NULL CHECK(position>=0),payload BLOB NOT NULL" + columns(table) + ")")
                try connection.execute("CREATE INDEX " + table.rawValue + "_owner ON " + table.rawValue + "(parent_id,position)")
            }
            try createIndexes(connection)
            try connection.execute("PRAGMA user_version=5")
        }
    }
}
