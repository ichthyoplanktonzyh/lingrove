import Foundation
import LingroveNotebook
import LingroveNotebookSync
import Testing
@testable import LingroveNotebookEngine

/// Real SQLite triggers reject unrelated writes. These tests verify that organization edits
/// retain lexical evidence, independent concurrent changes and review history atomically.
@MainActor
struct NotebookOrganizationIntegrationTests {
    @Test func independentEditsReuseCheckedStateAndWriteOnlyOrganizationRows() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = try saveSource(f)
        let entry = original.document.catalog[0], sense = entry.senses[0]
        _ = try f.db.enrollReviewNotes(selections: [.init(entryID: entry.id, senseID: sense.id)], version: .init(original))
        let baseline = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        let lineage = try #require(f.db.core.notebookSaveCache?.lineage)
        try protectUnrelatedRows(f.db)
        var first = baseline.document.semantics
        first.nodes[0].definition = "First editor"
        let saved = try f.db.saveNotebookOrganization(.init(semantics: first, basedOn: baseline.document.semantics),
            basedOn: baseline, operationId: "first-organization")
        var second = baseline.document.semantics
        second.nodes[1].definition = "Independent editor"
        let result = try f.db.saveNotebookOrganization(.init(semantics: second, basedOn: baseline.document.semantics),
            basedOn: saved, operationId: "second-organization")
        #expect(result.document.semantics.nodes.map(\.definition) == ["First editor", "Independent editor"])
        #expect(result.document.catalog == baseline.document.catalog)
        #expect(result.document.sources == baseline.document.sources && result.document.interpretations == baseline.document.interpretations)
        #expect(f.db.core.notebookSaveCache?.lineage == lineage)
        let entities = try f.db.core.query(sql: """
            SELECT DISTINCT entity FROM notebook_pending_rows WHERE operation_id IN ('first-organization','second-organization')
            """, values: []) { DatabaseCore.columnText(statement: $0, index: 0) }
        #expect(Set(entities) == ["meaning_nodes"])
        #expect(try f.db.core.scalarInt(sql: """
            SELECT COUNT(*) FROM notebook_pending_transactions
            WHERE operation_id IN ('first-organization','second-organization') AND has_public_change=1
            """, values: []) == 2)
        let noOp = try f.db.saveNotebookOrganization(.init(semantics: second, basedOn: baseline.document.semantics), basedOn: result)
        #expect(noOp == result)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == result)
    }

    @Test func conflictsAndInvalidRelationsLeaveTheWholeTransactionUnchanged() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let baseline = try saveSource(f)
        var edited = baseline.document.semantics
        edited.nodes[0].definition = "Committed"
        let saved = try f.db.saveNotebookOrganization(.init(semantics: edited, basedOn: baseline.document.semantics), basedOn: baseline)
        var stale = baseline.document.semantics
        stale.nodes[0].definition = "Stale"
        let count = try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspace)
        #expect(throws: VocabularyError.editConflict) {
            try f.db.saveNotebookOrganization(.init(semantics: stale, basedOn: baseline.document.semantics), basedOn: saved)
        }
        var invalid = saved.document.classification
        invalid.memberships.append(.init(id: UUID(), nodeID: UUID(), categoryID: invalid.categories[0].id))
        var combined = saved.document.semantics
        combined.nodes[1].definition = "Must roll back with the invalid membership"
        #expect(throws: VocabularyError.invalidContent) {
            try f.db.saveNotebookOrganization(.init(semantics: combined, semanticBaseline: saved.document.semantics,
                classification: invalid, classificationBaseline: saved.document.classification), basedOn: saved)
        }
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspace) == count)
    }

    @Test func lateJournalFailureRollsBackRowsRevisionAndPreparedCache() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let baseline = try saveSource(f)
        var edited = baseline.document.semantics
        edited.nodes[0].definition = "Retryable edit"
        let edit = try VocabularyOrganizationEdit(semantics: edited, basedOn: baseline.document.semantics)
        let count = try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspace)
        try f.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER fail_organization_journal BEFORE INSERT ON notebook_pending_rows
            WHEN NEW.operation_id='organization-failure'
            BEGIN SELECT RAISE(ABORT, 'Synthetic organization journal failure'); END;
            """, errorContext: "Install synthetic journal failure")
        #expect(throws: (any Error).self) {
            try f.db.saveNotebookOrganization(edit, basedOn: baseline, operationId: "organization-failure")
        }
        #expect(f.db.core.notebookSaveCache == nil)
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == baseline)
        #expect(try f.db.lingroveNotebookStore.pendingCount(workspaceId: f.workspace) == count)
        try f.db.core.executeScript(sql: "DROP TRIGGER fail_organization_journal;", errorContext: "Remove journal failure")
        let retried = try f.db.saveNotebookOrganization(edit, basedOn: baseline, operationId: "organization-failure")
        #expect(retried.document.semantics.nodes[0].definition == "Retryable edit")
    }

    @Test func removingMeaningsCompactsRowsAndPrunesMembershipsWithoutTouchingEvidence() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let baseline = try saveSource(f)
        try protectUnrelatedRows(f.db)
        var edited = baseline.document.semantics
        VocabularySemanticPolicy.removeNode(edited.nodes[0].id, from: &edited)
        let saved = try f.db.saveNotebookOrganization(.init(semantics: edited, basedOn: baseline.document.semantics),
            basedOn: baseline, operationId: "remove-meaning")
        #expect(saved.document.semantics.nodes.count == 1 && saved.document.classification.memberships.count == 1)
        #expect(saved.document.sources == baseline.document.sources && saved.document.catalog == baseline.document.catalog)
        #expect(try VocabularyWirePublicIntent.hasOrganizationChanges(from: baseline.document,
            to: saved.document, notebookID: saved.notebookId) ==
            VocabularyWirePublicIntent.hasChanges(from: baseline.document, to: saved.document, notebookID: saved.notebookId))
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
    }

    @Test func timestampOnlyChangesDoNotCreatePublicIntent() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let baseline = try saveSource(f)
        var edited = baseline.document.semantics
        edited.nodes[1].updatedAt = edited.nodes[1].updatedAt.addingTimeInterval(10)
        let saved = try f.db.saveNotebookOrganization(.init(semantics: edited, basedOn: baseline.document.semantics),
            basedOn: baseline, operationId: "organization-clock")
        #expect(saved.revision == baseline.revision + 1)
        #expect(try !VocabularyWirePublicIntent.hasChanges(from: baseline.document, to: saved.document,
            notebookID: saved.notebookId))
        #expect(try f.db.core.scalarInt(sql: """
            SELECT has_public_change FROM notebook_pending_transactions WHERE operation_id='organization-clock'
            """, values: []) == 0)
    }

    private func saveSource(_ f: NotebookMediaDatabaseFixture) throws -> LingroveNotebookSnapshot {
        var document = LingroveNotebookReviewCompletionTests.document()
        let senses = document.catalog[0].senses
        let nodes = senses.map { VocabularyMeaningNode(id: UUID(), labels: [.init(text: $0.meaning, language: .english)]) }
        document.semantics.nodes = nodes
        document.semantics.mappings = zip(nodes, senses).map { node, sense in .init(nodeID: node.id, senseID: sense.id) }
        let category = VocabularyCategory(id: UUID(), axis: .content, labels: [.init(text: "Synthetic category")])
        document.classification.categories = [category]
        document.classification.memberships = nodes.map { .init(id: UUID(), nodeID: $0.id, categoryID: category.id) }
        return try f.db.saveLingroveNotebook(document, basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
    }

    private func protectUnrelatedRows(_ engine: LingroveNotebookEngine) throws {
        for table in ["notebook_entries", "notebook_senses", "notebook_sources", "notebook_occurrences",
                      "notebook_usages", "notebook_collections", "cards", "notebook_review_material_state"] {
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                try engine.core.executeScript(sql: """
                    CREATE TEMP TRIGGER protect_\(table)_\(operation) BEFORE \(operation) ON \(table)
                    BEGIN SELECT RAISE(ABORT, 'Organization changed unrelated material'); END;
                    """, errorContext: "Protect synthetic corpus and review rows")
            }
        }
    }
}
