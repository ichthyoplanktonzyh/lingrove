import Foundation
import LingroveNotebook
import LingroveNotebookPersistenceCodec
import SQLite3
import XCTest
@testable import LingroveNotebookEngine

/// These tests cross the Nibomo facade, its shared SQLite connection, the notebook store, and
/// the portable persistence codec. They keep the real database boundary in the loop so schema,
/// workspace ownership, journaling, and reopen behavior are checked together.
final class LingroveNotebookStoreIntegrationTests: LocalDatabaseTestCase {
    func testFreshDatabaseRoundTripsContentAndTemplatePresenceAcrossReopen() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        XCTAssertEqual(LocalDatabaseSchema.currentVersion, try self.loadSchemaVersion(database: database))
        XCTAssertTrue(try database.core.tableExists(name: "notebook_state"))

        let empty = try database.loadLingroveNotebook(workspaceId: workspaceId)
        XCTAssertEqual(VocabularyDocument(), empty.document)
        XCTAssertNil(empty.document.reviewTemplates)

        let expression = "café\u{0000}猫"
        let note = "A saved note with Unicode 🐈 and an embedded\u{0000}separator."
        let document = Self.document(expression: expression, meaning: "a distinct sense 🌱", note: note)
        let saved = try database.saveLingroveNotebook(
            document,
            basedOn: empty,
            operationId: "notebook-round-trip"
        )
        XCTAssertNil(saved.document.reviewTemplates)
        XCTAssertEqual(0, try self.templatePresence(database: database, workspaceId: workspaceId))
        XCTAssertEqual([0], try self.journalTemplateFlags(database: database, workspaceId: workspaceId))

        let reopened = try self.reopen(database)
        let reloaded = try reopened.loadLingroveNotebook(workspaceId: workspaceId)
        XCTAssertEqual(saved, reloaded)
        let loadedEntry = try XCTUnwrap(reloaded.document.entries.first)
        XCTAssertEqual(expression, loadedEntry.expression)
        XCTAssertEqual(note, loadedEntry.senses.first?.note)
        XCTAssertEqual("🐈 said café in 東京.", loadedEntry.examples.first?.text)
        XCTAssertEqual([VocabularyTextRange(NSRange(location: 0, length: 2))], loadedEntry.examples.first?.ranges)

        // `nil` and `[]` encode the same number of template rows, so the notebook header carries
        // their distinct meaning. Reopen after both writes to test the durable representation.
        var explicitEmptyTemplates = reloaded.document
        explicitEmptyTemplates.reviewTemplates = []
        let emptyTemplatesSaved = try reopened.saveLingroveNotebook(
            explicitEmptyTemplates,
            basedOn: reloaded,
            operationId: "notebook-empty-templates"
        )
        XCTAssertTrue(try XCTUnwrap(emptyTemplatesSaved.document.reviewTemplates).isEmpty)
        XCTAssertEqual(1, try self.templatePresence(database: reopened, workspaceId: workspaceId))
        XCTAssertEqual([0, 1], try self.journalTemplateFlags(database: reopened, workspaceId: workspaceId))

        let reopenedAgain = try self.reopen(reopened)
        let emptyTemplatesReloaded = try reopenedAgain.loadLingroveNotebook(workspaceId: workspaceId)
        XCTAssertEqual(emptyTemplatesSaved, emptyTemplatesReloaded)
        XCTAssertTrue(try XCTUnwrap(emptyTemplatesReloaded.document.reviewTemplates).isEmpty)

        var missingTemplates = emptyTemplatesReloaded.document
        missingTemplates.reviewTemplates = nil
        let missingTemplatesSaved = try reopenedAgain.saveLingroveNotebook(
            missingTemplates,
            basedOn: emptyTemplatesReloaded,
            operationId: "notebook-missing-templates"
        )
        XCTAssertNil(missingTemplatesSaved.document.reviewTemplates)
        XCTAssertEqual(0, try self.templatePresence(database: reopenedAgain, workspaceId: workspaceId))

        let reopenedThird = try self.reopen(reopenedAgain)
        let missingTemplatesReloaded = try reopenedThird.loadLingroveNotebook(workspaceId: workspaceId)
        XCTAssertEqual(missingTemplatesSaved, missingTemplatesReloaded)
        XCTAssertNil(missingTemplatesReloaded.document.reviewTemplates)
        XCTAssertEqual([0, 1, 0], try self.journalTemplateFlags(database: reopenedThird, workspaceId: workspaceId))
    }

    func testCategoryKeyExchangeAndReplacementPreserveUnchangedChildren() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let initial = try database.loadLingroveNotebook(workspaceId: workspaceId)

        let framework = VocabularyClassificationFramework(id: Self.id(30), key: "integration.catalog", version: 1)
        let firstCategory = VocabularyCategory(
            id: Self.id(20), axis: .content,
            labels: [VocabularyMeaningLabel(id: Self.id(21), text: "First category", language: .english)],
            frameworkID: framework.id, key: "catalog.alpha"
        )
        let secondCategory = VocabularyCategory(
            id: Self.id(22), axis: .content,
            labels: [VocabularyMeaningLabel(id: Self.id(23), text: "Second category", language: .english)],
            frameworkID: framework.id, key: "catalog.beta"
        )
        let retiredCategory = VocabularyCategory(
            id: Self.id(24), axis: .content,
            labels: [VocabularyMeaningLabel(id: Self.id(25), text: "Retired category", language: .english)],
            frameworkID: framework.id, key: "catalog.retired"
        )
        let meaningNode = VocabularyMeaningNode(
            id: Self.id(40),
            labels: [VocabularyMeaningLabel(id: Self.id(41), text: "Shared meaning", language: .english)],
            createdAt: Self.referenceDate,
            updatedAt: Self.referenceDate
        )
        let originalClassification = VocabularyClassificationIndex(
            frameworks: [framework],
            categories: [firstCategory, secondCategory, retiredCategory],
            parents: [VocabularyCategoryParent(id: Self.id(32), categoryID: firstCategory.id, parentID: secondCategory.id)],
            memberships: [VocabularyMeaningCategoryMembership(id: Self.id(33), nodeID: meaningNode.id, categoryID: firstCategory.id)],
            overrides: [
                VocabularyCategoryOverride(categoryID: firstCategory.id, definition: "First local overlay"),
                VocabularyCategoryOverride(categoryID: secondCategory.id, definition: "Second local overlay")
            ]
        )
        var backupDocument = initial.document
        backupDocument.semantics.nodes = [meaningNode]
        backupDocument.classification = originalClassification

        // Framework catalog keys are protected by the incremental classification editor. A
        // complete backup restore may replace the catalog, while the final graph still has to
        // pass the shared domain validator before SQLite accepts it.
        let seeded = try database.saveLingroveNotebook(
            backupDocument,
            basedOn: initial,
            restoringBackup: true,
            operationId: "notebook-category-swap-seed"
        )
        var replacementDocument = seeded.document
        var replacementCategories = replacementDocument.classification.categories
        replacementCategories[0].key = "catalog.beta"
        replacementCategories[1].key = "catalog.alpha"
        let replacementCategory = VocabularyCategory(
            id: Self.id(26), axis: .content,
            labels: [VocabularyMeaningLabel(id: Self.id(27), text: "Replacement category", language: .english)],
            frameworkID: framework.id, key: "catalog.retired"
        )
        replacementCategories[2] = replacementCategory
        replacementDocument.classification.categories = replacementCategories

        let operationId = "notebook-category-key-exchange"
        let saved = try database.saveLingroveNotebook(
            replacementDocument,
            basedOn: seeded,
            restoringBackup: true,
            operationId: operationId
        )
        XCTAssertEqual(seeded.revision + 1, saved.revision)

        let reopened = try self.reopen(database)
        let reloaded = try reopened.loadLingroveNotebook(workspaceId: workspaceId)
        XCTAssertEqual(saved, reloaded)
        let categoriesByID = Dictionary(uniqueKeysWithValues: reloaded.document.classification.categories.map { ($0.id, $0) })
        XCTAssertEqual("catalog.beta", categoriesByID[firstCategory.id]?.key)
        XCTAssertEqual("catalog.alpha", categoriesByID[secondCategory.id]?.key)
        XCTAssertNil(categoriesByID[retiredCategory.id])
        XCTAssertEqual("catalog.retired", categoriesByID[replacementCategory.id]?.key)

        // These dependent rows keep their identities and category references while the owners
        // are replaced inside the transaction. Deferred NO ACTION foreign keys let them survive.
        XCTAssertEqual(originalClassification.frameworks, reloaded.document.classification.frameworks)
        XCTAssertEqual(originalClassification.parents, reloaded.document.classification.parents)
        XCTAssertEqual(originalClassification.memberships, reloaded.document.classification.memberships)
        XCTAssertEqual(originalClassification.overrides, reloaded.document.classification.overrides)
        XCTAssertEqual(1, try reopened.core.scalarInt(
            sql: "SELECT COUNT(*) FROM notebook_category_parents WHERE workspace_id = ?",
            values: [.text(workspaceId)]
        ))
        XCTAssertEqual(1, try reopened.core.scalarInt(
            sql: "SELECT COUNT(*) FROM notebook_category_memberships WHERE workspace_id = ?",
            values: [.text(workspaceId)]
        ))
        XCTAssertEqual(2, try reopened.core.scalarInt(
            sql: "SELECT COUNT(*) FROM notebook_category_overrides WHERE workspace_id = ?",
            values: [.text(workspaceId)]
        ))

        let categoryMutations = try self.journalMutations(database: reopened, operationId: operationId)
        XCTAssertEqual(
            [
                Self.id(20).uuidString: "upsert",
                Self.id(22).uuidString: "upsert",
                Self.id(24).uuidString: "delete",
                Self.id(26).uuidString: "upsert"
            ],
            Dictionary(uniqueKeysWithValues: categoryMutations.filter { $0.entity == "categories" }
                .map { ($0.entityID, $0.action) })
        )
        XCTAssertTrue(categoryMutations.allSatisfy { $0.entity == "categories" })
        XCTAssertEqual(
            PendingTransactionHeader(baseRevision: 1, revision: 2, hasTemplates: 0),
            try self.pendingHeader(database: reopened, operationId: operationId)
        )
        XCTAssertEqual(2, try reopened.lingroveNotebookStore.pendingCount(workspaceId: workspaceId))
        let foreignKeyViolations = try reopened.core.query(sql: "PRAGMA foreign_key_check", values: []) {
            DatabaseCore.columnText(statement: $0, index: 0)
        }
        XCTAssertTrue(foreignKeyViolations.isEmpty, "Category key replacement left foreign-key violations: \(foreignKeyViolations)")
    }

    func testEntryLookupKeyExchangePreservesSenseOwnershipAndJournal() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let initial = try database.loadLingroveNotebook(workspaceId: workspaceId)
        let firstEntryID = Self.id(50)
        let firstSenseID = Self.id(51)
        let secondEntryID = Self.id(52)
        let secondSenseID = Self.id(53)
        let document = VocabularyDocument(entries: [
            Self.simpleEntry(id: firstEntryID, senseID: firstSenseID, expression: "amber phrase", meaning: "First meaning"),
            Self.simpleEntry(id: secondEntryID, senseID: secondSenseID, expression: "violet phrase", meaning: "Second meaning")
        ])
        let seeded = try database.saveLingroveNotebook(
            document,
            basedOn: initial,
            restoringBackup: true,
            operationId: "notebook-entry-key-swap-seed"
        )

        var replacementDocument = seeded.document
        var replacementEntries = replacementDocument.entries
        for index in replacementEntries.indices {
            if replacementEntries[index].id == firstEntryID {
                replacementEntries[index].expression = "violet phrase"
                replacementEntries[index].dictionaryForm = "violet phrase"
            } else if replacementEntries[index].id == secondEntryID {
                replacementEntries[index].expression = "amber phrase"
                replacementEntries[index].dictionaryForm = "amber phrase"
            } else {
                XCTFail("Unexpected entry in the ownership-swap fixture")
            }
        }
        replacementDocument.entries = replacementEntries

        let operationId = "notebook-entry-lookup-exchange"
        let saved = try database.saveLingroveNotebook(
            replacementDocument,
            basedOn: seeded,
            restoringBackup: true,
            operationId: operationId
        )
        let reopened = try self.reopen(database)
        let reloaded = try reopened.loadLingroveNotebook(workspaceId: workspaceId)
        XCTAssertEqual(saved, reloaded)

        let entriesByID = Dictionary(uniqueKeysWithValues: reloaded.document.entries.map { ($0.id, $0) })
        XCTAssertEqual("violet phrase", entriesByID[firstEntryID]?.expression)
        XCTAssertEqual("amber phrase", entriesByID[secondEntryID]?.expression)
        XCTAssertEqual(firstSenseID, entriesByID[firstEntryID]?.senses.first?.id)
        XCTAssertEqual(secondSenseID, entriesByID[secondEntryID]?.senses.first?.id)
        XCTAssertEqual(2, try reopened.core.scalarInt(
            sql: "SELECT COUNT(*) FROM notebook_senses WHERE workspace_id = ?",
            values: [.text(workspaceId)]
        ))

        XCTAssertEqual(
            Set([
                JournalMutation(entity: "entries", entityID: firstEntryID.uuidString, action: "upsert"),
                JournalMutation(entity: "entries", entityID: secondEntryID.uuidString, action: "upsert")
            ]),
            Set(try self.journalMutations(database: reopened, operationId: operationId))
        )
        XCTAssertEqual(
            PendingTransactionHeader(baseRevision: 1, revision: 2, hasTemplates: 0),
            try self.pendingHeader(database: reopened, operationId: operationId)
        )
        XCTAssertEqual(2, try reopened.lingroveNotebookStore.pendingCount(workspaceId: workspaceId))
    }

    func testWorkspacesKeepDocumentsIndependentWhenEntityIDsMatch() throws {
        let database = try self.makeDatabase()
        let firstWorkspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let secondWorkspaceId = "notebook-isolation-workspace"
        let insertedRows = try database.core.execute(
            sql: """
            INSERT INTO workspaces (
                workspace_id, name, created_at, fsrs_algorithm, fsrs_desired_retention,
                fsrs_learning_steps_minutes_json, fsrs_relearning_steps_minutes_json,
                fsrs_maximum_interval_days, fsrs_enable_fuzz, fsrs_client_updated_at,
                fsrs_last_modified_by_replica_id, fsrs_last_operation_id, fsrs_updated_at
            )
            SELECT ?, 'Notebook isolation fixture', created_at, fsrs_algorithm, fsrs_desired_retention,
                fsrs_learning_steps_minutes_json, fsrs_relearning_steps_minutes_json,
                fsrs_maximum_interval_days, fsrs_enable_fuzz, fsrs_client_updated_at,
                fsrs_last_modified_by_replica_id, fsrs_last_operation_id, fsrs_updated_at
            FROM workspaces WHERE workspace_id = ?
            """,
            values: [.text(secondWorkspaceId), .text(firstWorkspaceId)]
        )
        XCTAssertEqual(1, insertedRows)

        let firstBaseline = try database.loadLingroveNotebook(workspaceId: firstWorkspaceId)
        let secondBaseline = try database.loadLingroveNotebook(workspaceId: secondWorkspaceId)
        XCTAssertNotEqual(firstBaseline.notebookId, secondBaseline.notebookId)

        let firstDocument = Self.document(expression: "first workspace", meaning: "first meaning", note: "first note")
        let secondDocument = Self.document(expression: "second workspace", meaning: "second meaning", note: "second note")
        let firstSaved = try database.saveLingroveNotebook(firstDocument, basedOn: firstBaseline)
        let secondSaved = try database.saveLingroveNotebook(secondDocument, basedOn: secondBaseline)

        XCTAssertEqual(firstSaved.document.entries.first?.id, secondSaved.document.entries.first?.id)
        XCTAssertEqual(firstSaved.document.entries.first?.senses.first?.id, secondSaved.document.entries.first?.senses.first?.id)
        XCTAssertEqual(firstSaved.document.entries.first?.examples.first?.id, secondSaved.document.entries.first?.examples.first?.id)

        let firstReloaded = try database.loadLingroveNotebook(workspaceId: firstWorkspaceId)
        let secondReloaded = try database.loadLingroveNotebook(workspaceId: secondWorkspaceId)
        XCTAssertEqual(firstSaved, firstReloaded)
        XCTAssertEqual(secondSaved, secondReloaded)
        XCTAssertEqual("first workspace", firstReloaded.document.entries.first?.expression)
        XCTAssertEqual("second workspace", secondReloaded.document.entries.first?.expression)
        XCTAssertEqual(1, try database.lingroveNotebookStore.pendingCount(workspaceId: firstWorkspaceId))
        XCTAssertEqual(1, try database.lingroveNotebookStore.pendingCount(workspaceId: secondWorkspaceId))
    }

    func testStaleRevisionAndDuplicateOperationRollBackDocumentHeaderAndJournal() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let initial = try database.loadLingroveNotebook(workspaceId: workspaceId)
        let committed = try database.saveLingroveNotebook(
            Self.document(expression: "committed expression", meaning: "committed meaning", note: "committed note"),
            basedOn: initial,
            operationId: "notebook-committed-operation"
        )
        let committedJournal = try self.journalCounts(database: database)

        XCTAssertThrowsError(try database.saveLingroveNotebook(
            Self.document(expression: "stale expression", meaning: "stale meaning", note: "stale note"),
            basedOn: initial,
            operationId: "notebook-stale-operation"
        )) { error in
            guard let vocabularyError = error as? VocabularyError,
                  case .editConflict = vocabularyError else {
                return XCTFail("Expected a stale-revision conflict, received: \(error)")
            }
        }
        XCTAssertEqual(committed, try database.loadLingroveNotebook(workspaceId: workspaceId))
        XCTAssertEqual(committedJournal, try self.journalCounts(database: database))

        XCTAssertThrowsError(try database.saveLingroveNotebook(
            Self.document(expression: "duplicate operation expression", meaning: "other meaning", note: "other note"),
            basedOn: committed,
            operationId: "notebook-committed-operation"
        )) { error in
            guard let localError = error as? LocalStoreError,
                  case .database = localError else {
                return XCTFail("Expected SQLite to reject the duplicate journal operation, received: \(error)")
            }
        }
        XCTAssertEqual(committed, try database.loadLingroveNotebook(workspaceId: workspaceId))
        XCTAssertEqual(committedJournal, try self.journalCounts(database: database))
    }

    func testJournalRowFailureRollsBackEveryNotebookWrite() throws {
        let database = try self.makeDatabase()
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId
        let initial = try database.loadLingroveNotebook(workspaceId: workspaceId)
        let committed = try database.saveLingroveNotebook(
            Self.document(expression: "before trigger", meaning: "stable meaning", note: "stable note"),
            basedOn: initial,
            operationId: "notebook-before-trigger"
        )
        let committedJournal = try self.journalCounts(database: database)
        try database.core.executeScript(
            sql: """
            CREATE TRIGGER reject_notebook_journal_row
            BEFORE INSERT ON notebook_pending_rows
            BEGIN
                SELECT RAISE(ABORT, 'integration fixture rejects journal row');
            END;
            """,
            errorContext: "Failed to install the journal rollback fixture"
        )

        XCTAssertThrowsError(try database.saveLingroveNotebook(
            Self.document(expression: "after trigger", meaning: "replacement meaning", note: "replacement note"),
            basedOn: committed,
            operationId: "notebook-triggered-failure"
        )) { error in
            guard let localError = error as? LocalStoreError,
                  case .database = localError else {
                return XCTFail("Expected the journal insert to fail as a database error, received: \(error)")
            }
        }

        XCTAssertEqual(committed, try database.loadLingroveNotebook(workspaceId: workspaceId))
        XCTAssertEqual(committedJournal, try self.journalCounts(database: database))
        try database.core.executeScript(
            sql: "DROP TRIGGER reject_notebook_journal_row;",
            errorContext: "Failed to remove the journal rollback fixture"
        )
    }





    private func reopen(_ database: LocalDatabase) throws -> LocalDatabase {
        try database.close()
        self.database = nil
        let reopened = try LocalDatabase(databaseURL: try XCTUnwrap(self.databaseURL))
        self.database = reopened
        return reopened
    }

    private func journalCounts(database: LocalDatabase) throws -> JournalCounts {
        JournalCounts(
            transactions: try database.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_pending_transactions", values: []),
            rows: try database.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_pending_rows", values: [])
        )
    }

    private func templatePresence(database: LocalDatabase, workspaceId: String) throws -> Int {
        try database.core.scalarInt(
            sql: "SELECT has_templates FROM notebook_state WHERE workspace_id = ?",
            values: [.text(workspaceId)]
        )
    }

    private func journalTemplateFlags(database: LocalDatabase, workspaceId: String) throws -> [Int] {
        try database.core.query(
            sql: "SELECT has_templates FROM notebook_pending_transactions WHERE workspace_id = ? ORDER BY revision",
            values: [.text(workspaceId)]
        ) { statement in
            Int(DatabaseCore.columnInt64(statement: statement, index: 0))
        }
    }

    private func journalMutations(database: LocalDatabase, operationId: String) throws -> [JournalMutation] {
        try database.core.query(
            sql: "SELECT entity,entity_id,action FROM notebook_pending_rows WHERE operation_id = ? ORDER BY entity,entity_id",
            values: [.text(operationId)]
        ) { statement in
            JournalMutation(
                entity: DatabaseCore.columnText(statement: statement, index: 0),
                entityID: DatabaseCore.columnText(statement: statement, index: 1),
                action: DatabaseCore.columnText(statement: statement, index: 2)
            )
        }
    }

    private func pendingHeader(database: LocalDatabase, operationId: String) throws -> PendingTransactionHeader {
        let headers = try database.core.query(
            sql: "SELECT base_revision,revision,has_templates FROM notebook_pending_transactions WHERE operation_id = ?",
            values: [.text(operationId)]
        ) { statement in
            PendingTransactionHeader(
                baseRevision: Int(DatabaseCore.columnInt64(statement: statement, index: 0)),
                revision: Int(DatabaseCore.columnInt64(statement: statement, index: 1)),
                hasTemplates: Int(DatabaseCore.columnInt64(statement: statement, index: 2))
            )
        }
        return try XCTUnwrap(headers.first)
    }

    /// Make the current file represent the schema-25 boundary after releasing the app connection.
    /// The production reset SQL owns the child-first table list; no legacy tables or card data are
    /// touched by this fixture mutation.
    private func prepareSchema25Fixture(at databaseURL: URL) throws {
        var connection: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard openResult == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let connection { sqlite3_close_v2(connection) }
            throw LocalStoreError.database("Failed to open the migration fixture: \(message)")
        }
        defer { sqlite3_close_v2(connection) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            if let errorMessage { sqlite3_free(errorMessage) }
        }
        let sql = LingroveNotebookSchema.resetSQL + "\nPRAGMA user_version = 25;"
        let result = sql.withCString { sqlite3_exec(connection, $0, nil, nil, &errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            throw LocalStoreError.database("Failed to prepare the schema-25 fixture: \(message)")
        }
    }

    private static func document(expression: String, meaning: String, note: String) -> VocabularyDocument {
        let example = VocabularyExample(
            id: Self.id(3),
            sourceID: Self.id(4),
            occurrenceID: Self.id(5),
            sourceKind: .captured,
            text: "🐈 said café in 東京.",
            translation: "猫说咖啡。",
            translationLanguage: .chinese,
            translationVariants: [VocabularyMeaning(text: "A cat said it.", language: .english)],
            ranges: [VocabularyTextRange(NSRange(location: 0, length: 2))],
            completeness: .sentence,
            meaning: "a usage specific to this sentence",
            meaningLanguage: .english,
            meaningOrigin: .user,
            appBundleIdentifier: "com.example.reader",
            createdAt: Self.referenceDate
        )
        let sense = VocabularySense(
            id: Self.id(2),
            meaning: meaning,
            meaningLanguage: .english,
            meaningOrigin: .user,
            note: note,
            tags: ["captured", "猫"],
            examples: [example],
            content: [VocabularyContentBlock(
                id: Self.id(6),
                content: .text(VocabularyTextContent(text: "A formatted note with 🐈.", style: .paragraph, bold: true))
            )],
            createdAt: Self.referenceDate,
            updatedAt: Self.referenceDate
        )
        let entry = VocabularyEntry(
            id: Self.id(1),
            expression: expression,
            dictionaryForm: expression,
            language: .english,
            kind: .expression,
            senses: [sense],
            createdAt: Self.referenceDate,
            updatedAt: Self.referenceDate
        )
        return VocabularyDocument(entries: [entry])
    }

    private static func simpleEntry(id: UUID, senseID: UUID, expression: String, meaning: String) -> VocabularyEntry {
        let sense = VocabularySense(
            id: senseID,
            meaning: meaning,
            meaningLanguage: .english,
            meaningOrigin: .user,
            createdAt: Self.referenceDate,
            updatedAt: Self.referenceDate
        )
        return VocabularyEntry(
            id: id,
            expression: expression,
            dictionaryForm: expression,
            language: .english,
            kind: .word,
            senses: [sense],
            createdAt: Self.referenceDate,
            updatedAt: Self.referenceDate
        )
    }

    private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }
}

private struct JournalCounts: Equatable {
    let transactions: Int
    let rows: Int
}

/// A decoded pending-row mutation lets the integration suite compare the durable journal delta
/// without depending on SQLite row order. Each value lives only for the test assertion that reads it.
private struct JournalMutation: Hashable {
    let entity: String
    let entityID: String
    let action: String
}

/// These transaction-level fields remain meaningful when an edit changes no entity rows, such as
/// nil-to-empty template presence. The test case owns each decoded snapshot for one assertion.
private struct PendingTransactionHeader: Equatable {
    let baseRevision: Int
    let revision: Int
    let hasTemplates: Int
}
