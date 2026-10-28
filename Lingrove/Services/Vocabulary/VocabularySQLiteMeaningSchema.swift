import Foundation

/// SQL constraints enforce the same graph boundaries as the pure policy. This adapter belongs
/// to the archive's connection, not the UI: joins remain inspectable and SQLite can reject an
/// orphan link even if a future caller bypasses the normal editor validation.
nonisolated enum VocabularySQLiteMeaningSchema {
    // Keep the typed table dispatch exhaustive; each case describes an independent row format.
    // swiftlint:disable:next cyclomatic_complexity
    static func columns(_ table: VocabularyDatabaseRecord.Table) -> String {
        let deferred = " DEFERRABLE INITIALLY DEFERRED"
        switch table {
        case .usages:
            return ",occurrence_id TEXT NOT NULL REFERENCES occurrences(id)" + deferred +
                ",sense_id TEXT REFERENCES senses(id)" + deferred +
                ",status TEXT NOT NULL CHECK(status IN ('candidate','accepted','rejected'))"
        case .collections:
            return ",sense_id TEXT NOT NULL UNIQUE REFERENCES senses(id)" + deferred
        case .collectionInterpretations:
            return ",usage_id TEXT NOT NULL REFERENCES usages(id)" + deferred + ",UNIQUE(parent_id,usage_id)"
        case .meaningNodes:
            return ",kind TEXT NOT NULL CHECK(kind IN ('concept','function'))"
        case .meaningLabels:
            return ",language TEXT NOT NULL,text TEXT NOT NULL,preferred TEXT NOT NULL CHECK(preferred IN ('yes','no'))"
        case .meaningRoles, .patternSlots:
            return ",name TEXT NOT NULL"
        case .usagePatterns:
            return ",template TEXT NOT NULL,UNIQUE(id,parent_id)"
        case .meaningMappings:
            return ",meaning_id TEXT NOT NULL REFERENCES meaning_nodes(id) ON DELETE CASCADE" + deferred +
                ",pattern_id TEXT,relation TEXT NOT NULL CHECK(relation IN ('expressesContent','realizesFunction'))," +
                "FOREIGN KEY(pattern_id,parent_id) REFERENCES usage_patterns(id,parent_id) ON DELETE CASCADE" + deferred
        case .mappingRoles:
            return ",role_id TEXT NOT NULL REFERENCES meaning_roles(id) ON DELETE CASCADE" + deferred +
                ",slot_id TEXT NOT NULL REFERENCES pattern_slots(id) ON DELETE CASCADE" + deferred
        case .mappingEvidence:
            return ",usage_id TEXT NOT NULL REFERENCES usages(id) ON DELETE CASCADE" + deferred
        case .meaningRelations:
            return ",target_id TEXT NOT NULL REFERENCES meaning_nodes(id) ON DELETE CASCADE" + deferred +
                ",relation TEXT NOT NULL CHECK(relation IN ('narrower','opposite','related')),CHECK(parent_id<>target_id)"
        case .retrievalCues:
            return ",language TEXT NOT NULL,text TEXT NOT NULL"
        case .cueTargets:
            return ",meaning_id TEXT NOT NULL REFERENCES meaning_nodes(id) ON DELETE CASCADE" + deferred +
                ",UNIQUE(parent_id,meaning_id)"
        default: return ""
        }
    }

    static func createIndexes(_ connection: VocabularySQLiteConnection) throws {
        for sql in [
            "CREATE INDEX usages_occurrence ON usages(occurrence_id,status)",
            "CREATE INDEX usages_sense ON usages(sense_id,status)",
            "CREATE UNIQUE INDEX meaning_preferred_language ON meaning_labels(parent_id,language) WHERE preferred='yes'",
            "CREATE INDEX meaning_label_text ON meaning_labels(language,text)",
            "CREATE INDEX meaning_mappings_node ON meaning_mappings(meaning_id,parent_id)",
            "CREATE INDEX meaning_relations_target ON meaning_relations(target_id)",
            "CREATE INDEX retrieval_cue_text ON retrieval_cues(language,text)",
            "CREATE INDEX cue_targets_meaning ON cue_targets(meaning_id)",
            "CREATE INDEX mapping_evidence_usage ON mapping_evidence(usage_id)"
        ] { try connection.execute(sql) }
    }
}
