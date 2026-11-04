import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

@MainActor
struct ReviewNoteTargetTests {
    @Test func preparingForAnkiNeverEnrollsOnSourceTypeOrCustomFieldUpdates() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let scope = try f.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let entry = scope.document.collectedEntries[0], sense = entry.senses[0]
        let selection = VocabularySelection(entryID: entry.id, senseID: sense.id)
        let preview = try f.db.previewReviewNote(selection: selection, type: ReviewNoteDefaults.type, scope: scope)
        #expect(try ReviewNoteStore(core: f.db.core).notes(scope: scope).isEmpty)
        let prepared = try f.db.prepareReviewNote(selection: selection, type: ReviewNoteDefaults.type, scope: scope)
        #expect(prepared.id == preview.id)
        var document = scope.document
        document.entries[0].senses[0].meaning = "Updated while only using Anki"
        let updated = try f.db.saveLingroveNotebook(document, basedOn: scope)
        var type = ReviewNoteDefaults.type; type.revision += 1
        let field = ReviewNoteField(name: "Hint", source: .custom); type.fields.append(field)
        type.templates[0].back += "{{Hint}}"
        try f.db.saveReviewNoteType(type, expected: ReviewNoteDefaults.type, scope: updated)
        var note = prepared; note.revision += 1; note.customFields[field.id.uuidString.lowercased()] = "My note"
        try f.db.saveReviewNote(note, expected: prepared, scope: updated)
        #expect(try f.db.loadLingroveNotebookReviewSnapshot(scope: updated).groups.isEmpty)
        #expect(try f.db.cardStore.loadCardsIncludingDeleted(workspaceId: f.workspace).isEmpty)
        try f.reopen()
        let selected = try f.db.enrollReviewNotes(selections: [selection], type: type, scope: updated)
        #expect(selected.first?.id == prepared.id && selected.first?.customFields == note.customFields)
        #expect(try f.db.loadBuiltInNotebookReview(scope: updated, now: Date()).queue.count == 1)
    }
}
