import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

/// Fresh SQLite connections exercise the public local command, never a warm decoded corpus.
/// Successful receipts are checked against a subsequent complete lossless load; fallbacks
/// and injected failures must leave canonical rows, revision and review history unchanged.
@MainActor
struct NotebookLocalEntryIntegrationTests {
    @Test func cancellationBeforeCommandAdmissionDoesNotWrite() async throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture)
        try fixture.reopen()
        let incoming = entry("cancelled")
        let task = Task { @MainActor in
            // Cancel only this child. The parent remains able to inspect durable state.
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.db.trySaveNotebookEntry(incoming, basedOn: .init(saved))
        }
        switch await task.result {
        case let .failure(error): #expect(error is CancellationError)
        case .success: Issue.record("A cancelled command entered the writer")
        }
        #expect(try fixture.db.currentNotebookVersion() == .init(saved))
        #expect(try fixture.db.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_entries WHERE workspace_id=?",
            values: [.text(fixture.workspace)]) == 1)
    }

    @Test func coldAppendAndRetirementPreserveUnrelatedEvidenceAndSemantics() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let entries = [entry("first", senses: 2), entry("second")]
        var document = VocabularyDocument(entries: entries)
        document.reviewTemplates = []
        let nodes = entries[0].senses.map { _ in VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Concept")]) }
        document.semantics.nodes = nodes
        document.semantics.mappings = zip(nodes, entries[0].senses).map {
            .init(nodeID: $0.0.id, senseID: $0.1.id, evidenceIDs: [$0.1.examples[0].id])
        }
        _ = try fixture.db.saveLingroveNotebook(document, basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        try fixture.reopen()
        let version = try #require(try fixture.db.currentNotebookVersion()), added = entry("new")
        let receipt = try #require(try fixture.db.trySaveNotebookEntry(added, basedOn: version, operationId: "local-append"))
        #expect(receipt.version.revision == version.revision + 1 && receipt.entry?.id == added.id)
        #expect(fixture.db.core.notebookSaveCache == nil)
        let after = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        #expect(after.document.entries.count == 3 && after.document.semantics == document.semantics)
        #expect(after.document.reviewTemplates == [])
        #expect(after.document.entries.first { $0.id == entries[1].id } == entries[1])
        try fixture.reopen()
        let removal = try #require(try fixture.db.tryRemoveNotebookSense(entries[0].senses[0].id, from: entries[0].id,
            basedOn: .init(after), operationId: "local-retire"))
        #expect(removal.entry?.senses.count == 1 && removal.changesSemantics)
        #expect(fixture.db.core.notebookSaveCache == nil)
        let removed = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        #expect(removed.document.sources == after.document.sources && removed.document.occurrences == after.document.occurrences)
        #expect(removed.document.semantics.nodes.sorted { $0.id.uuidString < $1.id.uuidString } ==
            document.semantics.nodes.sorted { $0.id.uuidString < $1.id.uuidString })
        #expect(removed.document.semantics.mappings.count == 1)
        try fixture.reopen()
        let last = try #require(try fixture.db.tryRemoveNotebookSense(entries[0].senses[1].id, from: entries[0].id,
            basedOn: .init(removed)))
        #expect(last.entry == nil)
        let finished = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        #expect(finished.document.catalog.count == 2 && finished.document.semantics.mappings.isEmpty)
        #expect(finished.document.sources == removed.document.sources && finished.document.reviewTemplates == [])
        #expect(try fixture.db.core.scalarInt(sql: """
            SELECT COUNT(*) FROM notebook_pending_transactions WHERE operation_id IN ('local-append','local-retire')
            """,
            values: []) == 2)
    }

    @Test func pendingJournalFailureRollsBackRowsHeaderAndCertificate() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        _ = try seed(fixture)
        try fixture.reopen()
        let version = try #require(try fixture.db.currentNotebookVersion()), added = entry("retryable")
        let proof = try fixture.db.core.scalarOptionalText(sql: "SELECT media_sha256 FROM notebook_entry_checkpoint WHERE workspace_id=?",
            values: [.text(fixture.workspace)])
        try fixture.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER reject_local_journal BEFORE INSERT ON notebook_pending_rows
            WHEN NEW.operation_id='failed-local' BEGIN SELECT RAISE(ABORT,'Synthetic journal failure'); END;
            """, errorContext: "Inject local command failure")
        #expect(throws: (any Error).self) { try fixture.db.trySaveNotebookEntry(added, basedOn: version, operationId: "failed-local") }
        #expect(try fixture.db.currentNotebookVersion() == version)
        #expect(try fixture.db.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_entries WHERE workspace_id=? AND id=?",
            values: [.text(fixture.workspace), .text(added.id.uuidString)]) == 0)
        #expect(try fixture.db.core.scalarOptionalText(sql: "SELECT media_sha256 FROM notebook_entry_checkpoint WHERE workspace_id=?",
            values: [.text(fixture.workspace)]) == proof)
        #expect(try fixture.db.trySaveNotebookEntry(added, basedOn: version, operationId: "retry-local") != nil)
    }

    @Test func rawSameRevisionMutationRevokesCertificateAndFullValidationRejectsCorruption() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture)
        try fixture.reopen()
        try fixture.db.core.execute(sql: "UPDATE notebook_entries SET expression='wrong index' WHERE workspace_id=?",
            values: [.text(fixture.workspace)])
        #expect(try fixture.db.trySaveNotebookEntry(entry("must not write"), basedOn: .init(saved)) == nil)
        #expect(fixture.db.core.notebookSaveCache == nil)
        #expect(throws: VocabularyError.invalidArchive) { try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace) }
    }

    @Test func missingTamperedAndSchemaStaleCertificatesRequestFullPreparation() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        var saved = try seed(fixture)
        for mutation in ["DELETE FROM notebook_entry_checkpoint",
                         "UPDATE notebook_entry_checkpoint SET media_sha256='damaged'",
                         "UPDATE notebook_entry_checkpoint SET validation_version=0",
                         "CREATE INDEX extra_local_test_index ON notebook_entries(workspace_id,expression)"] {
            try fixture.reopen()
            try fixture.db.core.executeScript(sql: mutation, errorContext: "Invalidate a derived certificate")
            #expect(try fixture.db.trySaveNotebookEntry(entry("fallback"), basedOn: .init(saved)) == nil)
            #expect(try fixture.db.currentNotebookVersion() == .init(saved))
            saved = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        }
        try fixture.reopen()
        #expect(try fixture.db.trySaveNotebookEntry(entry("certified"), basedOn: .init(saved)) != nil)
    }

    @Test func globalAliasesBodyAndSemanticIDsCannotBeClaimedByAnotherEntry() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let alias = UUID(), block = VocabularyContentBlock(content: .text(.init(text: "Retained body")))
        let planID = UUID(), legacyPlanID = UUID()
        var original = entry("owner")
        original.senses[0].mergedFrom = [alias]; original.senses[0].content = [block]
        original.senses[0].reviewCards = [.init(plan: .init(id: planID, layout: .init()))]
        original.senses[0].review = .init(plan: .init(id: legacyPlanID))
        var document = VocabularyDocument(entries: [original])
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Meaning")])
        document.semantics.nodes = [node]
        let saved = try fixture.db.saveLingroveNotebook(document, basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        try fixture.reopen()
        for id in [alias, block.id, planID, node.id] {
            var incoming = entry("collision-\(id)")
            incoming.senses[0] = .init(id: id, meaning: "Collision", createdAt: Date(), updatedAt: Date())
            #expect(throws: VocabularyError.invalidArchive) { try fixture.db.trySaveNotebookEntry(incoming, basedOn: .init(saved)) }
        }
        #expect(try fixture.db.currentNotebookVersion() == .init(saved))
        var legacy = entry("legacy namespace")
        legacy.senses[0] = .init(id: legacyPlanID, meaning: "Allowed local scope", createdAt: Date(), updatedAt: Date())
        #expect(try fixture.db.trySaveNotebookEntry(legacy, basedOn: .init(saved)) != nil)
    }

    @Test func staleGenerationFailsBeforeAnyLocalMutation() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture)
        try fixture.reopen()
        try fixture.db.core.execute(sql: """
            UPDATE notebook_window_binding SET generation=lower(hex(randomblob(16))) WHERE settings_id=1
            """, values: [])
        #expect(throws: VocabularyError.editConflict) { try fixture.db.trySaveNotebookEntry(entry("wrong owner"), basedOn: .init(saved)) }
    }

    @Test func reviewedCapturesAndImageReferenceChangesKeepFullPreparation() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture)
        let original = try #require(saved.document.entries.first)
        _ = try fixture.db.enrollReviewNotes(selections: [.init(entryID: original.id, senseID: original.senses[0].id)],
            version: .init(saved))
        try fixture.reopen()
        #expect(try NotebookEntryCheckpoint.load(in: fixture.db.core, version: .init(saved)) != nil)
        #expect(try fixture.db.trySaveNotebookEntry(original, basedOn: .init(saved)) == nil)
        #expect(try fixture.db.trySaveNotebookEntry(entry("unrelated to review"), basedOn: .init(saved)) != nil)
        let image = try LingroveNotebookMediaQueueIntegrationTests.image()
        let next = try fixture.db.saveLingroveNotebook(LingroveNotebookMediaQueueIntegrationTests.document(image.reference),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace), images: [image.reference.filename: image.data])
        try fixture.reopen()
        let target = try #require(next.document.entries.first)
        #expect(try fixture.db.tryRemoveNotebookSense(target.senses[0].id, from: target.id, basedOn: .init(next)) == nil)
        #expect(try fixture.db.currentNotebookVersion() == .init(next))
    }

    @Test func currentMediaOwnershipIsCheckedEvenWhenTheCorpusClockIsUnchanged() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let image = try LingroveNotebookMediaQueueIntegrationTests.image()
        let saved = try fixture.db.saveLingroveNotebook(LingroveNotebookMediaQueueIntegrationTests.document(image.reference),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace), images: [image.reference.filename: image.data])
        try fixture.reopen()
        try fixture.db.core.execute(sql: "DELETE FROM notebook_media_assets WHERE workspace_id=?", values: [.text(fixture.workspace)])
        #expect(throws: VocabularyError.invalidContent) { try fixture.db.trySaveNotebookEntry(entry("ownership"), basedOn: .init(saved)) }
        #expect(try fixture.db.currentNotebookVersion() == .init(saved))
    }

    private func seed(_ fixture: NotebookMediaDatabaseFixture) throws -> LingroveNotebookSnapshot {
        try fixture.db.saveLingroveNotebook(.init(entries: [entry("seed", senses: 2)]),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
    }

    private func entry(_ name: String, senses count: Int = 1) -> VocabularyEntry {
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        return .init(id: UUID(), expression: name, dictionaryForm: name, language: .english, kind: .word,
            senses: (0..<count).map { index in
                .init(id: UUID(), meaning: "Meaning \(index)",
                    examples: [.init(id: UUID(), text: "A retained sentence.", translation: "A translation", ranges: [],
                        completeness: .sentence, meaning: "", createdAt: now)], createdAt: now, updatedAt: now)
            }, createdAt: now, updatedAt: now)
    }
}
