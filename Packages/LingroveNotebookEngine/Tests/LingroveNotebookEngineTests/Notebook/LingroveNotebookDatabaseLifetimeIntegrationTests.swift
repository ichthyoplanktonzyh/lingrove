import Foundation
import LingroveNotebook
import XCTest
@testable import LingroveNotebookEngine

/// Exercises the notebook and card facades against a real SQLite file across connection close.
/// Reopening the same file proves that rejected operations neither revive the old handle nor
/// change data that was committed before close.
final class LingroveNotebookDatabaseLifetimeIntegrationTests: LocalDatabaseTestCase {
    func testClosedDatabaseRejectsNotebookCardAndSQLAccessWithoutChangingCommittedData() throws {
        let database = try self.makeDatabase()
        let databaseURL = try XCTUnwrap(self.databaseURL)
        let workspaceId = try database.workspaceSettingsStore.loadWorkspace().workspaceId

        let emptyNotebook = try database.loadLingroveNotebook(workspaceId: workspaceId)
        let importedDocument = Self.document(expression: "original notebook entry")
        let committedNotebook = try database.saveLingroveNotebook(
            importedDocument,
            basedOn: emptyNotebook,
            restoringBackup: true,
            operationId: "database-lifetime-import-\(UUID().uuidString.lowercased())"
        )
        XCTAssertEqual(1, committedNotebook.revision)

        let originalCard = try XCTUnwrap(database.createCards(
            workspaceId: workspaceId,
            inputs: [
                CardEditorInput(
                    frontText: "original card front",
                    backText: "original card back",
                    tags: ["lifetime"]
                )
            ]
        ).first)

        try database.close()
        // Closing an already closed core is intentionally idempotent for owners with cleanup paths.
        try database.close()

        self.assertDatabaseClosed {
            try database.loadLingroveNotebook(workspaceId: workspaceId)
        }

        self.assertDatabaseClosed {
            try database.saveLingroveNotebook(
                Self.document(expression: "rejected notebook replacement"),
                basedOn: committedNotebook,
                restoringBackup: true,
                operationId: "database-lifetime-rejected-\(UUID().uuidString.lowercased())"
            )
        }

        self.assertDatabaseClosed {
            try database.loadActiveCard(workspaceId: workspaceId, cardId: originalCard.cardId)
        }

        var transactionBodyRan = false
        self.assertDatabaseClosed {
            try database.core.inTransaction {
                transactionBodyRan = true
            }
        }
        XCTAssertFalse(transactionBodyRan, "A closed database must reject before entering transaction work")

        self.assertDatabaseClosed {
            try database.core.query(sql: "SELECT 1", values: []) { statement in
                Int(DatabaseCore.columnInt64(statement: statement, index: 0))
            }
        }

        self.assertDatabaseClosed {
            try database.core.execute(sql: "DELETE FROM notebook_state", values: [])
        }

        self.assertDatabaseClosed {
            try database.core.executeScript(sql: "DELETE FROM notebook_state", errorContext: "closed database test")
        }


        let reopened = try LocalDatabase(databaseURL: databaseURL)
        self.database = reopened
        let reloadedNotebook = try reopened.loadLingroveNotebook(workspaceId: workspaceId)
        XCTAssertEqual(committedNotebook, reloadedNotebook)
        XCTAssertEqual(committedNotebook.notebookId, reloadedNotebook.notebookId)
        XCTAssertEqual(1, reloadedNotebook.revision)
        XCTAssertEqual(importedDocument, reloadedNotebook.document)
        XCTAssertEqual(originalCard, try reopened.loadActiveCard(workspaceId: workspaceId, cardId: originalCard.cardId))
    }

    private func assertDatabaseClosed<T>(
        _ operation: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case LocalStoreError.database(let message) = error else {
                return XCTFail("Expected a closed-database error, received: \(error)", file: file, line: line)
            }
            XCTAssertEqual("Database connection is closed", message, file: file, line: line)
        }
    }

    private static func document(expression: String) -> VocabularyDocument {
        let now = Date()
        let sense = VocabularySense(
            id: UUID(),
            meaning: "A meaning that should remain committed",
            meaningLanguage: .english,
            meaningOrigin: .user,
            createdAt: now,
            updatedAt: now
        )
        let entry = VocabularyEntry(
            id: UUID(),
            expression: expression,
            dictionaryForm: expression,
            language: .english,
            kind: .word,
            senses: [sense],
            createdAt: now,
            updatedAt: now
        )
        return VocabularyDocument(entries: [entry])
    }
}
