import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

/// Real transactional clocks protect cache authority without timing assertions. Every scenario
/// owns a disposable database; a second connection exercises the same boundary used by CLI/sync.
@MainActor
struct NotebookChangeTrackingIntegrationTests {
    @Test func ratingAndAcknowledgementKeepTheTrustedCorpus() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try source(f)
        _ = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        let lineage = try #require(f.db.core.notebookSaveCache?.lineage)
        let before = try f.db.notebookChanges().stamp
        let selection = VocabularySelection(entryID: saved.document.catalog[0].id, senseID: saved.document.catalog[0].senses[0].id)
        _ = try f.db.enrollReviewNotes(selections: [selection], version: .init(saved))
        let content = try f.db.loadBuiltInNotebookReview(scope: saved, now: Date())
        let card = try #require(content.review.groups[selection.senseID]?.cards.first)
        _ = try f.db.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), card: card,
            action: .init(content: content, selection: selection))
        let rated = try f.db.notebookChanges().stamp
        #expect(rated.corpus == before.corpus && rated.review != before.review && rated.progress != before.progress)
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
        #expect(f.db.core.notebookSaveCache?.lineage == lineage)
        let fence = try f.db.notebookProgressReadFence()
        let other = try LingroveNotebookEngine(databaseURL: f.url, mediaDirectoryURL: f.db.core.mediaDirectoryURL)
        defer { try? other.close() }
        // These are real transport-side mutations: journal removal and an advanced pull cursor.
        try other.core.inTransaction {
            try other.core.execute(sql: "DELETE FROM notebook_pending_transactions WHERE workspace_id=?", values: [.text(f.workspace)])
            try other.core.execute(sql: "INSERT OR REPLACE INTO notebook_review_sync_state(workspace_id,after_sequence) VALUES(?,12)",
                values: [.text(f.workspace)])
        }
        let acknowledged = try f.db.notebookChanges().stamp
        #expect(acknowledged.changes(since: rated) == .synchronization)
        #expect(try f.db.notebookProgressReadFence() == fence)
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
        #expect(f.db.core.notebookSaveCache?.lineage == lineage)
    }

    @Test func organizationAndNoOpUpdatesDoNotInvalidateProgress() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try source(f)
        let fence = try f.db.notebookProgressReadFence()
        let before = try f.db.notebookChanges().stamp
        var semantics = saved.document.semantics
        semantics.nodes.append(.init(id: UUID(), labels: [.init(text: "Organization fixture")], definition: "An organization-only node"))
        let after = try f.db.saveNotebookOrganization(.init(semantics: semantics, basedOn: saved.document.semantics), basedOn: saved)
        #expect(after.revision > saved.revision)
        #expect(try f.db.notebookProgressReadFence() == fence)
        let changed = try f.db.notebookChanges().stamp
        #expect(changed.changes(since: before) == [.corpus, .synchronization])
        try f.db.core.execute(sql: "UPDATE notebook_senses SET payload_json=payload_json WHERE workspace_id=?", values: [.text(f.workspace)])
        #expect(try f.db.notebookChanges().stamp == changed)
        let result = try f.db.loadNotebookProgress(scope: fence.scope, now: Date(), calendar: .current)
        #expect(result.scope.revision == after.revision)
    }

    @Test func rawWritesAndRollbackRemainConservative() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try source(f)
        _ = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        let before = try f.db.notebookChanges().stamp
        enum Rollback: Error { case expected }
        #expect(throws: Rollback.self) {
            try f.db.core.inTransaction {
                try f.db.core.execute(sql: "UPDATE notebook_senses SET payload_json='invalid-json' WHERE workspace_id=?", values: [.text(f.workspace)])
                #expect(try f.db.core.notebookChangeStamp().corpus != before.corpus)
                throw Rollback.expected
            }
        }
        #expect(try f.db.notebookChanges().stamp == before)
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
        let other = try LingroveNotebookEngine(databaseURL: f.url, mediaDirectoryURL: f.db.core.mediaDirectoryURL)
        defer { try? other.close() }
        try other.core.execute(sql: "UPDATE notebook_senses SET payload_json='invalid-json' WHERE workspace_id=?", values: [.text(f.workspace)])
        #expect(try f.db.notebookChanges().stamp.corpus != before.corpus)
        #expect(throws: (any Error).self) { try f.db.loadLingroveNotebook(workspaceId: f.workspace) }
    }

    @Test func missingTriggerFallsBackUntilTheNextWriterRepairsIt() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        _ = try source(f)
        _ = try f.db.notebookChanges()
        try f.db.core.executeScript(sql: "DROP TRIGGER notebook_clock_1_notebook_senses_update;", errorContext: "Simulate incomplete tracking")
        let before = try f.db.notebookChanges().stamp
        try f.db.core.execute(sql: "UPDATE notebook_senses SET payload_json='invalid' WHERE workspace_id=?", values: [.text(f.workspace)])
        let changed = try f.db.notebookChanges().stamp
        #expect(changed.corpus != before.corpus)
        #expect(throws: (any Error).self) { try f.db.loadLingroveNotebook(workspaceId: f.workspace) }
        try f.reopen()
        #expect(try NotebookChangeTracking.isInstalled(in: f.db.core))
    }

    @Test func existingSchemaInstallsTrackingAndReadOnlyHostsDoNotWrite() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try source(f)
        let names = try f.db.core.query(sql: "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'notebook_clock_%'", values: []) {
            DatabaseCore.columnText(statement: $0, index: 0)
        }
        try f.db.core.executeScript(sql: names.map { "DROP TRIGGER \($0);" }.joined() + "DROP TABLE notebook_change_clock;",
            errorContext: "Simulate an existing notebook before tracking metadata")
        let reader = try LingroveNotebookEngine(readOnlyDatabaseURL: f.url, mediaDirectoryURL: f.db.core.mediaDirectoryURL)
        #expect(try reader.loadNotebookProgress(scope: reader.notebookProgressReadFence().scope, now: Date(), calendar: .current).totalReviews == 0)
        #expect(try !reader.core.tableExists(name: "notebook_change_clock"))
        try reader.close()
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
        #expect(try f.db.core.tableExists(name: "notebook_change_clock"))
        let stamp = try f.db.notebookChanges().stamp
        try f.db.core.execute(sql: "UPDATE notebook_senses SET payload_json='broken' WHERE workspace_id=?", values: [.text(f.workspace)])
        #expect(try f.db.notebookChanges().stamp.corpus != stamp.corpus)
    }

    private func source(_ f: NotebookMediaDatabaseFixture) throws -> LingroveNotebookSnapshot {
        try f.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
    }
}
