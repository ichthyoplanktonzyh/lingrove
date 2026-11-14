import Foundation
import Testing
import LingroveNotebook
@testable import LingroveNotebookEngine

/// Compound writes must retain the same atomicity as a full save while touching only selected
/// lexical/semantic groups. Every database here is private synthetic state.
@MainActor
struct NotebookEntryBatchTests {
    @Test func appendProofMatchesSequentialPreparationAndRejectsCrossMemberIdentities() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = try f.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let batch = try VocabularyEntryInputPolicy.batch((0..<12).map {
            .init(expression: "append\($0)", meaning: "Meaning \($0)", example: "An append\($0) example.")
        }, existing: [], now: Date(timeIntervalSince1970: 1_700_000_000))
        let cached = try #require(f.db.core.notebookSaveCache)
        let appended = try cached.state.appendingEntries(batch.entries)
        var sequential = cached.state
        for entry in batch.entries { sequential = try sequential.replacing(entry).state }
        #expect(appended.state.document == sequential.document)
        #expect(appended.state.entries == sequential.entries)
        var invalid = batch.entries
        invalid[1].senses[0] = invalid[0].senses[0]
        #expect(throws: (any Error).self) { try f.db.saveNotebookEntries(invalid, basedOn: original) }
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == original)
        let saved = try f.db.saveNotebookEntries(batch.entries, basedOn: original)
        #expect(saved.document == sequential.document)
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace).document == sequential.document)
    }

    @Test func batchUsesOneRevisionAndFailureLeavesNoPartialEntries() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let original = try f.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let inputs = [VocabularyEntryInput(expression: "first", meaning: "First meaning"),
            .init(expression: "second", meaning: "Second meaning")]
        let batch = try VocabularyEntryInputPolicy.batch(inputs, existing: [], now: Date())
        let rejected = try #require(batch.entries.last)
        try f.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER reject_batch_entry BEFORE INSERT ON notebook_entries
            WHEN NEW.id='\(rejected.id.uuidString)'
            BEGIN SELECT RAISE(ABORT,'Synthetic batch failure'); END;
            """, errorContext: "Fail one member of the batch")
        #expect(throws: (any Error).self) { try f.db.saveNotebookEntries(batch.entries, basedOn: original) }
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace) == original)
        try f.db.core.executeScript(sql: "DROP TRIGGER reject_batch_entry;", errorContext: "Remove failure")
        let saved = try f.db.saveNotebookEntries(batch.entries, basedOn: original)
        #expect(saved.revision == original.revision + 1)
        #expect(saved.document.entries.count == original.document.entries.count + 2)
        let receipt = try #require(try f.db.committedNotebookChange(for: .init(saved)))
        #expect(Set(receipt.updatedEntries.map(\.id)) == Set(batch.entries.map(\.id)))
        #expect(throws: VocabularyError.editConflict) { try f.db.saveNotebookEntries(batch.entries, basedOn: original) }
        try f.reopen()
        #expect(try f.db.loadLingroveNotebook(workspaceId: f.workspace).document == saved.document)
    }

    @Test func mergeUndoRestoresOwnedPatternsAndMappingsWithoutEditingSharedNodes() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        var document = LingroveNotebookReviewCompletionTests.document()
        let entry = document.entries[0], sense = entry.senses[0]
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Harbor")])
        let pattern = VocabularyUsagePattern(senseID: sense.id, template: "A harbor")
        document.semantics = .init(nodes: [node], patterns: [pattern], mappings: [
            .init(nodeID: node.id, senseID: sense.id, patternID: pattern.id, evidenceIDs: sense.examples.map(\.id))])
        let before = try f.db.saveLingroveNotebook(document,
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        _ = try f.db.enrollReviewNotes(selections: [.init(entryID: entry.id, senseID: sense.id)], version: .init(before))
        var merged = entry
        try VocabularySenseEditingPolicy.merge(source: sense.id, into: entry.senses[1].id, in: &merged, now: Date())
        let saved = try f.db.saveNotebookEntry(merged, basedOn: before)
        let restored = try f.db.saveNotebookEntries([entry], basedOn: saved, restoringOwnedSemantics: before.document.semantics)
        #expect(restored.document.entries.first { $0.id == entry.id } == entry)
        #expect(restored.document.semantics == before.document.semantics)
        #expect(try f.db.loadBuiltInNotebookReview(scope: restored, now: Date()).statistics.exercises == 1)
    }
}
