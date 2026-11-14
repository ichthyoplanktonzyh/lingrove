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
        #expect(finished.document.sources == removed.document.sources)
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
        var original = entry("owner")
        original.senses[0].mergedFrom = [alias]; original.senses[0].content = [block]
        var document = VocabularyDocument(entries: [original])
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Meaning")])
        document.semantics.nodes = [node]
        let saved = try fixture.db.saveLingroveNotebook(document, basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        try fixture.reopen()
        for id in [alias, block.id, node.id] {
            var incoming = entry("collision-\(id)")
            incoming.senses[0] = .init(id: id, meaning: "Collision", createdAt: Date(), updatedAt: Date())
            #expect(throws: VocabularyError.invalidArchive) { try fixture.db.trySaveNotebookEntry(incoming, basedOn: .init(saved)) }
        }
        #expect(try fixture.db.currentNotebookVersion() == .init(saved))

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

    @Test func reviewedCapturesAndImageRetirementStayLocal() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture)
        let original = try #require(saved.document.entries.first)
        _ = try fixture.db.enrollReviewNotes(selections: [.init(entryID: original.id, senseID: original.senses[0].id)],
            version: .init(saved))
        try fixture.reopen()
        #expect(try NotebookEntryCheckpoint.load(in: fixture.db.core, version: .init(saved)) != nil)
        #expect(try fixture.db.trySaveNotebookEntry(original, basedOn: .init(saved)) != nil)
        #expect(try fixture.db.trySaveNotebookEntry(entry("unrelated to review"), basedOn: .init(saved)) != nil)
        let image = try LingroveNotebookMediaQueueIntegrationTests.image()
        let next = try fixture.db.saveLingroveNotebook(LingroveNotebookMediaQueueIntegrationTests.document(image.reference),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace), images: [image.reference.filename: image.data])
        try fixture.reopen()
        let target = try #require(next.document.entries.first)
        #expect(try fixture.db.tryRemoveNotebookSense(target.senses[0].id, from: target.id, basedOn: .init(next)) != nil)
        #expect(try fixture.db.currentNotebookVersion()?.revision == next.revision + 1)
    }

    @Test func citedExampleEditRetractsOnlyItsEvidenceAndSharedNodesSurvive() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let entries = [entry("edited"), entry("unchanged")]
        var document = VocabularyDocument(entries: entries)
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Shared concept")])
        document.semantics.nodes = [node]
        document.semantics.mappings = entries.map {
            .init(nodeID: node.id, senseID: $0.senses[0].id, evidenceIDs: [$0.examples[0].id])
        }
        let saved = try fixture.db.saveLingroveNotebook(document, basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        try fixture.reopen()
        var next = try #require(saved.document.entries.first { $0.id == entries[0].id })
        next.senses[0].examples[0].meaning = "Corrected interpretation"
        let receipt = try #require(try fixture.db.trySaveNotebookEntry(next, basedOn: .init(saved)))
        #expect(receipt.changesSemantics && fixture.db.core.notebookSaveCache == nil)
        let after = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        let updated = try #require(after.document.semantics.mappings.first { $0.senseID == next.senses[0].id })
        #expect(updated.evidenceIDs.isEmpty && updated.provenance.status == .proposed)
        #expect(after.document.semantics.nodes == [node])
        #expect(after.document.semantics.mappings.first { $0.senseID == entries[1].senses[0].id } == document.semantics.mappings[1])
    }

    @Test func sharedSourcesAreReusedWhileAcceptedOccurrencesAndClaimsCannotBeStolen() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture), original = try #require(saved.document.entries.first)
        try fixture.reopen()
        var incoming = entry("shared source")
        incoming.senses[0].examples = [original.examples[0].copiedWithNewID()]
        let receipt = try #require(try fixture.db.trySaveNotebookEntry(incoming, basedOn: .init(saved)))
        #expect(receipt.entry?.examples[0].sourceID == original.examples[0].sourceID)
        #expect(fixture.db.core.notebookSaveCache == nil)
        var stolen = entry("stolen occurrence")
        stolen.senses[0].examples = [original.examples[0].copiedWithNewID()]
        stolen.senses[0].examples[0].occurrenceID = original.examples[0].occurrenceID ?? original.examples[0].id
        #expect(throws: VocabularyError.invalidArchive) { try fixture.db.trySaveNotebookEntry(stolen, basedOn: receipt.version) }
        stolen.senses[0].examples = [original.examples[0]]
        #expect(try fixture.db.trySaveNotebookEntry(stolen, basedOn: receipt.version) == nil)
        let after = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        #expect(after.document.sources.count == saved.document.sources.count)
        #expect(after.document.interpretations.count == saved.document.interpretations.count + 1)
    }

    @Test func localImagesKeepSharedPinsAndReleaseTheLastOwner() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let image = try LingroveNotebookMediaQueueIntegrationTests.image()
        var owners = [entry("first image"), entry("second image")]
        for index in owners.indices {
            owners[index].senses[0].content = [.init(content: .image(image.reference, caption: "Owned"))]
        }
        let saved = try fixture.db.saveLingroveNotebook(.init(entries: owners),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace), images: [image.reference.filename: image.data])
        try fixture.reopen()
        var first = try #require(saved.document.entries.first { $0.id == owners[0].id })
        first.senses[0].content = []
        let removed = try #require(try fixture.db.trySaveNotebookEntry(first, basedOn: .init(saved)))
        #expect(try NotebookEntryCheckpoint.load(in: fixture.db.core, version: removed.version)?.media == [image.reference])
        let second = try #require(try fixture.db.notebookEntryDetail(entryID: owners[1].id).entry)
        let last = try #require(try fixture.db.tryRemoveNotebookSense(second.senses[0].id, from: second.id, basedOn: removed.version))
        #expect(try NotebookEntryCheckpoint.load(in: fixture.db.core, version: last.version)?.media.isEmpty == true)
        #expect(try fixture.db.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_media_pins WHERE consumer_id='document'",
            values: []) == 0)
        first.senses[0].content = [.init(content: .image(image.reference, caption: "Reused owned bytes"))]
        let added = try #require(try fixture.db.trySaveNotebookEntry(first, basedOn: last.version))
        let full = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        #expect(full.revision == added.version.revision &&
            VocabularyDocumentValidation.imageReferences(full.document) == [image.reference])
    }

    @Test func suppliedImageAndSiblingOwnershipStayLocalAndMetadataCanBeRepaired() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let image = try LingroveNotebookMediaQueueIntegrationTests.image(), saved = try seed(fixture)
        try fixture.reopen()
        var owner = try #require(saved.document.entries.first)
        owner.senses[0].content = [.init(content: .image(image.reference, caption: "Supplied"))]
        let added = try #require(try fixture.db.trySaveNotebookEntry(owner, basedOn: .init(saved),
            images: [image.reference.filename: image.data]))
        #expect(fixture.db.core.notebookSaveCache == nil)
        var document = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace).document
        var sibling = entry("sibling")
        sibling.senses[0].content = [.init(content: .image(image.reference, caption: "Sibling owner"))]
        document.entries.append(sibling)
        let shared = try fixture.db.saveLingroveNotebook(document,
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        try fixture.reopen()
        try fixture.db.core.execute(sql: "UPDATE media_blob_cache SET mime_type='image/jpeg' WHERE sha256=?",
            values: [.text(image.reference.digest)])
        owner.senses[0].content = []
        let removed = try #require(try fixture.db.trySaveNotebookEntry(owner, basedOn: .init(shared)))
        #expect(try NotebookEntryCheckpoint.load(in: fixture.db.core, version: removed.version)?.media == [image.reference])
        #expect(try fixture.db.core.scalarOptionalText(sql: "SELECT mime_type FROM media_blob_cache WHERE sha256=?",
            values: [.text(image.reference.digest)]) == "image/png")
        let full = try fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace)
        #expect(full.revision > added.version.revision)
    }

    @Test func reviewedMaterialFailureRollsBackEntryJournalAndCertificate() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let saved = try seed(fixture), original = try #require(saved.document.entries.first)
        _ = try fixture.db.enrollReviewNotes(selections: [.init(entryID: original.id, senseID: original.senses[0].id)],
            version: .init(saved))
        try fixture.reopen()
        try fixture.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER reject_live_refresh BEFORE UPDATE ON notebook_review_material_state
            BEGIN SELECT RAISE(ABORT,'Synthetic material failure'); END;
            """, errorContext: "Inject late refresh failure")
        var edited = original; edited.senses[0].note = "Must roll back"
        #expect(throws: (any Error).self) {
            try fixture.db.trySaveNotebookEntry(edited, basedOn: .init(saved), operationId: "late-rollback")
        }
        #expect(try fixture.db.currentNotebookVersion() == .init(saved))
        #expect(try NotebookEntryCheckpoint.load(in: fixture.db.core, version: .init(saved)) != nil)
        #expect(try fixture.db.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_pending_transactions WHERE operation_id='late-rollback'",
            values: []) == 0)
        #expect(try fixture.db.notebookEntryDetail(entryID: original.id).entry == original)
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
