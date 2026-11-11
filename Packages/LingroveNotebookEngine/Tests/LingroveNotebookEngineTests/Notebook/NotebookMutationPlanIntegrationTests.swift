import Foundation
import Testing
import LingroveNotebook
import LingroveNotebookPersistenceCodec
@testable import LingroveNotebookEngine

/// Private SQLite fixtures cross the same mutation seam as native editors. These checks
/// protect retained memory, unrelated materials and receipt/cache authority independently of
/// timing; a faster save is not acceptable if it loses a review or admits stale state.
@MainActor
struct NotebookMutationPlanIntegrationTests {
    @Test func removingOneMemberDoesNotRewriteSurvivorsAndPermutationIsANoop() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        var saved = try saveSources(f)
        let target = saved.document.entries[0], sense = target.senses[0]
        let removedClaims = sense.examples.map { "'" + $0.id.uuidString + "'" }.joined(separator: ",")
        try f.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER protect_other_claim_delete BEFORE DELETE ON notebook_usages
            WHEN OLD.id NOT IN (\(removedClaims)) BEGIN SELECT RAISE(ABORT,'Surviving interpretation rewritten'); END;
            CREATE TEMP TRIGGER protect_other_claim_update BEFORE UPDATE ON notebook_usages
            BEGIN SELECT RAISE(ABORT,'Interpretation rank updated'); END;
            CREATE TEMP TRIGGER protect_other_sense_delete BEFORE DELETE ON notebook_senses
            WHEN OLD.id<>'\(sense.id.uuidString)' BEGIN SELECT RAISE(ABORT,'Surviving sense rewritten'); END;
            """, errorContext: "Protect unordered members")
        var permuted = saved.document
        permuted.catalog.reverse(); permuted.sources.reverse(); permuted.interpretations.reverse()
        let noop = try f.db.saveLingroveNotebook(permuted, basedOn: saved)
        #expect(noop.revision == saved.revision)
        saved = try f.db.removeNotebookSense(sense.id, from: target.id, basedOn: saved)
        let pending = try f.db.core.scalarInt(sql: """
            SELECT COUNT(*) FROM notebook_pending_rows r JOIN notebook_pending_transactions t USING(operation_id)
            WHERE t.revision=?
            """, values: [.integer(Int64(saved.revision))])
        #expect(pending < 10)
        #expect(saved.document.entries.count == 1)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
    }

    @Test func existingPositionValuesAreIgnoredForMembershipButBodyOrderStillPersists() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = try saveSources(f)
        // Simulate an existing database without migrating or dropping its authored payloads.
        try f.db.core.execute(sql: "UPDATE notebook_entries SET position=731", values: [])
        try f.db.core.execute(sql: "UPDATE notebook_senses SET position=951", values: [])
        try f.db.core.execute(sql: "UPDATE notebook_usages SET position=1234", values: [])
        var saved = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        #expect(saved == original)
        var entry = try #require(saved.document.entries.first { $0.id == original.document.entries[0].id })
        entry.senses[0].content = ["Before", "After"].map { .init(content: .text(.init(text: $0))) }
        saved = try f.db.saveNotebookEntry(entry, basedOn: saved)
        entry.senses[0].content?.reverse()
        saved = try f.db.saveNotebookEntry(entry, basedOn: saved)
        try f.reopen()
        let reopened = try f.db.loadLingroveNotebook(workspaceId: f.workspace)
        #expect(reopened.document.entries.first { $0.id == entry.id }?.senses[0].content == entry.senses[0].content)
        #expect(reopened == saved)
    }

    @Test func evidenceDeltaKeepsUnrelatedGraphRowsAndMatchesTheFullCodec() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = try saveSources(f)
        var document = original.document
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Synthetic graph node", language: .english)])
        document.semantics.nodes = [node]
        document.semantics.patterns = document.entries.map {
            .init(senseID: $0.senses[0].id, template: "A synthetic pattern")
        }
        document.semantics.mappings = zip(document.entries, document.semantics.patterns).map { entry, pattern in
            .init(nodeID: node.id, senseID: entry.senses[0].id, patternID: pattern.id,
                evidenceIDs: entry.senses[0].examples.map(\.id), provenance: .init(status: .confirmed))
        }
        var saved = try f.db.saveLingroveNotebook(document, basedOn: original)
        try f.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER protect_graph_nodes BEFORE DELETE ON notebook_meaning_nodes
            BEGIN SELECT RAISE(ABORT,'Unrelated meaning node rewritten'); END;
            """, errorContext: "Protect unrelated synthetic graph")
        for step in 0..<2 {
            let cache = try #require(f.db.core.notebookSaveCache)
            var entry = cache.state.entries[0]
            entry.senses[0].examples[0].meaning = "New reading \(step)"
            let change = try cache.state.replacing(entry)
            #expect(change.semanticChange.updatedMappings.count == (step == 0 ? 1 : 0))
            let delta = try cache.projection.applying(change)
            let expected = try VocabularyPersistenceCodec.encode(change.document).keyedRows()
            #expect(try delta.projection.rows(reviewTemplatesPresent: false).keyedRows() == expected)
            #expect(!delta.changed.contains { [.meaningNodes, .meaningLabels, .usagePatterns].contains($0.entity) })
            saved = try f.db.saveNotebookEntry(entry, basedOn: saved)
        }
        let target = saved.document.entries[0]
        saved = try f.db.removeNotebookSense(target.senses[0].id, from: target.id, basedOn: saved)
        #expect(saved.document.semantics.mappings.count == 1)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
    }

    @Test func deletingNoteSourceRetainsMemoryAndCanRestoreMaterial() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = try saveSources(f)
        let entry = original.document.entries[0], sense = entry.senses[0]
        let selection = VocabularySelection(entryID: entry.id, senseID: sense.id)
        _ = try f.db.enrollReviewNotes(selections: [selection], version: .init(original))
        let content = try f.db.loadBuiltInNotebookReview(scope: original, now: Date())
        let card = try #require(content.queue.first)
        _ = try f.db.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), card: card,
            action: .init(content: content, selection: selection))
        let rated = try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId)
        let removed = try f.db.removeNotebookSense(sense.id, from: entry.id, basedOn: original)
        #expect(!removed.document.entries.contains { $0.id == entry.id })
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId) == rated)
        #expect(try f.db.loadReviewEventCount() == 1)
        #expect(try material(f, card.cardId) == "sourceMissing")
        let unavailable = try f.db.loadBuiltInNotebookReview(scope: removed, now: Date())
        #expect(unavailable.noteCards[card.cardId] != nil)
        #expect(unavailable.review.groups[sense.id]?.hasUnavailableMaterial == true)
        let restored = try f.db.saveLingroveNotebook(original.document, basedOn: removed, restoringBackup: true)
        #expect(try material(f, card.cardId) == "ready")
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId).reps == rated.reps)
        #expect(try f.db.loadReviewEventCount() == 1)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == restored)
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card.cardId).dueAt == rated.dueAt)
    }

    @Test func fullSaveRefreshesOnlyChangedSourceAndRetainsItsCheckedCache() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = try saveSources(f)
        let entries = original.document.entries
        let selections = entries.map { VocabularySelection(entryID: $0.id, senseID: $0.senses[0].id) }
        _ = try f.db.enrollReviewNotes(selections: selections, version: .init(original))
        let content = try f.db.loadBuiltInNotebookReview(scope: original, now: Date())
        let other = try #require(content.review.groups[selections[1].senseID]?.cards.first)
        try f.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER protect_other_material BEFORE UPDATE ON notebook_review_material_state
            WHEN OLD.card_id='\(other.cardId)' BEGIN SELECT RAISE(ABORT,'Unrelated Note refreshed'); END;
            """, errorContext: "Protect unrelated synthetic material")
        let lineage = try #require(f.db.core.notebookSaveCache?.lineage)
        var next = original.document
        next.catalog[0].senses[0].note = "One edited note"
        let saved = try f.db.saveLingroveNotebook(next, basedOn: original)
        #expect(f.db.core.notebookSaveCache?.lineage == lineage)
        let receipt = try #require(try f.db.committedNotebookChange(for: .init(saved)))
        #expect(receipt.base == LingroveNotebookVersion(original))
        #expect(receipt.updatedEntries.map(\.id) == [entries[0].id])
        #expect(receipt.removedEntryIDs.isEmpty && !receipt.requiresEntryReload)
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
        #expect(f.db.core.notebookSaveCache?.lineage == lineage)
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: other.cardId) == other)
    }

    @Test func lateFailureRollsBackRowsAndRevokesPreparedReceipts() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = try saveSources(f)
        var next = original.document; next.catalog[0].senses[0].note = "Must roll back"
        try f.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER fail_journal BEFORE INSERT ON notebook_pending_rows
            BEGIN SELECT RAISE(ABORT,'Synthetic journal failure'); END;
            """, errorContext: "Reject synthetic journal")
        #expect(throws: (any Error).self) { try f.db.saveLingroveNotebook(next, basedOn: original) }
        #expect(f.db.core.notebookSaveCache == nil)
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == original)
        #expect(try f.db.committedNotebookChange(for: .init(original)) == nil)
    }

    @Test func indexedValidationRejectsCrossOwnerOccurrencesAndInvalidLifecycleFields() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = try saveSources(f)
        let entries = original.document.entries
        var stolen = entries[0]
        let other = entries[1].senses[0].examples[0]
        stolen.senses[0].examples[0].sourceID = other.sourceID
        stolen.senses[0].examples[0].occurrenceID = other.occurrenceID ?? other.id
        stolen.senses[0].examples[0].text = other.text
        #expect(throws: (any Error).self) { try f.db.saveNotebookEntry(stolen, basedOn: original) }
        var invalid = entries[0]
        invalid.senses[0].tags = Array(repeating: "tag", count: 101)
        #expect(throws: (any Error).self) { try f.db.saveNotebookEntry(invalid, basedOn: original) }
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == original)
    }

    @Test func indexedValidationPreservesTheLexicalSemanticIDNamespace() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = try saveSources(f)
        var document = original.document
        let now = Date(), id = UUID()
        document.semantics.nodes = [.init(id: id, labels: [.init(text: "A shared meaning", language: .english)],
            createdAt: now, updatedAt: now)]
        let saved = try f.db.saveLingroveNotebook(document, basedOn: original)
        var entry = saved.document.entries[0]
        entry.senses.append(.init(id: id, meaning: "Invalid reused semantic ID", createdAt: now, updatedAt: now))
        #expect(throws: (any Error).self) { try f.db.saveNotebookEntry(entry, basedOn: saved) }
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == saved)
    }

    private func material(_ f: NotebookMediaDatabaseFixture, _ card: String) throws -> String {
        try f.db.core.scalarText(sql: "SELECT status FROM notebook_review_material_state WHERE card_id=?", values: [.text(card)])
    }

    private func saveSources(_ f: NotebookMediaDatabaseFixture) throws -> LingroveNotebookSnapshot {
        let now = Date()
        let entries: [VocabularyEntry] = ["harbor", "forest"].map { word in
            .init(id: UUID(), expression: word, dictionaryForm: word, language: .english, kind: .word,
                senses: [.init(id: UUID(), meaning: "Synthetic \(word)", note: "Original note",
                    examples: [.init(id: UUID(), sourceKind: .authored, text: "We found a quiet \(word).",
                        translation: "Synthetic translation", ranges: [], completeness: .sentence,
                        meaning: "", createdAt: now)], createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)
        }
        return try f.db.saveLingroveNotebook(.init(entries: entries),
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
    }
}
