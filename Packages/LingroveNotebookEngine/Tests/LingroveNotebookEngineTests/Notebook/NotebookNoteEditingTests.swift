import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

@MainActor struct NotebookNoteEditingTests {
    @Test func coldFormAndPreviewIgnoreUnrelatedCorpusAndRetainHistoryOnSave() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let now = Date()
        let entries = (0..<2).map { number in
            VocabularyEntry(id: UUID(), expression: "word\(number)", dictionaryForm: "word\(number)", language: .english, kind: .word,
                senses: [.init(id: UUID(), meaning: "meaning \(number)", note: "source note", createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)
        }
        let scope = try f.db.saveLingroveNotebook(.init(entries: entries), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        _ = try f.db.enrollReviewNotes(selections: entries.map { .init(entryID: $0.id, senseID: $0.senses[0].id) }, version: .init(scope))
        let review = try f.db.loadLingroveNotebookReviewSnapshot(scope: scope)
        let card = try #require(review.noteCards.first { $0.value.note.senseID == entries[0].senses[0].id })
        _ = try f.db.submitNotebookRating(.init(cardId: card.key, rating: .good, reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC",
            noteVersion: card.value.questionVersion(in: scope)), basedOn: scope)
        try f.reopen()
        try f.db.core.execute(sql: "UPDATE notebook_entries SET payload_json='{}' WHERE workspace_id=? AND id=?",
            values: [.text(f.workspace), .text(entries[1].id.uuidString)])
        let form = try f.db.notebookNoteEditor(cardID: card.key, workspaceID: f.workspace)
        #expect(form.entry.id == entries[0].id && form.entry.senses.count == 1)
        #expect(f.db.core.notebookSaveCache == nil)
        let preview = try f.db.previewNotebookNote(form.model, basedOn: form)
        #expect(preview.rendered.backHTML.contains("meaning 0"))
        var note = form.model.note; note.revision += 1
        note.exampleID = nil
        let edit = try f.db.saveReviewNoteWithReceipt(note, expected: form.model.note, version: form.fence.version,
            expectedCorpus: form.fence.corpus, expectedType: form.model.noteType)
        #expect(edit.selection?.senseIDs.contains(note.senseID) == true)
        #expect(try f.db.loadReviewEventCount() == 1 && f.db.core.notebookSaveCache == nil)
        var style = form.model.noteType; style.revision += 1; style.css += "\np{color:orange}"
        _ = try f.db.saveReviewNoteTypeWithReceipt(style, expected: form.model.noteType, version: form.fence.version,
            expectedCorpus: form.fence.corpus)
        #expect(throws: VocabularyError.editConflict) { try f.db.previewNotebookNote(form.model, basedOn: form) }
        #expect(try f.db.loadReviewEventCount() == 1)
    }

    @Test func sourceAndOwnerClocksRejectStaleFormsWithoutWrites() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let now = Date(), sense = VocabularySense(id: UUID(), meaning: "meaning", createdAt: Date(), updatedAt: Date())
        let entry = VocabularyEntry(id: UUID(), expression: "word", dictionaryForm: "word", language: .english,
            kind: .word, senses: [sense], createdAt: now, updatedAt: now)
        let scope = try f.db.saveLingroveNotebook(.init(entries: [entry]), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        _ = try f.db.enrollReviewNotes(selections: [.init(entryID: entry.id, senseID: sense.id)], version: .init(scope))
        let card = try #require(try f.db.loadLingroveNotebookReviewSnapshot(scope: scope).noteCards.keys.first)
        let form = try f.db.notebookNoteEditor(cardID: card, workspaceID: f.workspace)
        var note = form.model.note; note.revision += 1
        try f.db.core.execute(sql: "UPDATE notebook_collections SET payload_json=json_set(payload_json,'$.note','raw change') WHERE workspace_id=?", values: [.text(f.workspace)])
        #expect(throws: VocabularyError.editConflict) {
            try f.db.saveReviewNoteWithReceipt(note, expected: form.model.note, version: form.fence.version, expectedCorpus: form.fence.corpus)
        }
        let fresh = try f.db.notebookNoteEditor(cardID: card, workspaceID: f.workspace)
        try f.db.core.execute(sql: "UPDATE notebook_window_binding SET generation=?", values: [.text(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())])
        #expect(throws: VocabularyError.editConflict) {
            try f.db.saveReviewNoteTypeWithReceipt(fresh.model.noteType, expected: fresh.model.noteType,
                version: fresh.fence.version, expectedCorpus: fresh.fence.corpus)
        }
        #expect(try f.db.loadReviewEventCount() == 0)
    }
}
