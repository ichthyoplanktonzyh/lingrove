import Foundation
import Testing
import LingroveNotebook
@testable import LingroveNotebookEngine

/// Private SQLite fixtures cross the same mutation seam as native editors. These checks
/// protect retained memory, unrelated materials and receipt/cache authority independently of
/// timing; a faster save is not acceptable if it loses a review or admits stale state.
@MainActor
struct NotebookMutationPlanIntegrationTests {
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
