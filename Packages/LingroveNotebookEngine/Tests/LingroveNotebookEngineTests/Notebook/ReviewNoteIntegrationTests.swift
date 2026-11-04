import Foundation
import Testing
import LingroveNotebook
@testable import LingroveNotebookEngine

@MainActor
struct ReviewNoteIntegrationTests {
    @Test func noteCreatesIndependentCardsAndReplaysWithoutDuplication() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selection) = try source(fixture)
        var type = ReviewNoteDefaults.type
        type.id = UUID(); type.name = "Two directions"
        type.templates.append(.init(name: "Recall", front: "{{Meaning}}", back: "{{Expression}}"))
        try fixture.db.saveReviewNoteType(type, expected: nil, scope: scope, makeDefault: true)
        let notes = try fixture.db.enrollReviewNotes(selections: [selection], type: type, scope: scope)
        _ = try fixture.db.enrollReviewNotes(selections: [selection], type: type, scope: scope)
        let review = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        #expect(notes.count == 1 && review.queue.count == 2 && review.noteCards.count == 2)
        #expect(Set(review.noteCards.values.map { $0.note.id }).count == 1)
        let card = try #require(review.queue.first)
        _ = try fixture.db.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), card: card, action: .init(content: review, selection: selection))
        let after = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        #expect(after.review.groups[selection.senseID]?.cards.filter { $0.reps == 1 }.count == 1)
        #expect(after.review.groups[selection.senseID]?.cards.filter { $0.reps == 0 }.count == 1)
        try fixture.reopen()
        #expect(try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date()).noteCards.count == 2)
    }
    @Test func templateEditFencesRatingAndPreservesMemory() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selection) = try source(fixture)
        let type = ReviewNoteDefaults.type
        _ = try fixture.db.enrollReviewNotes(selections: [selection], type: type, scope: scope)
        let before = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let card = try #require(before.queue.first)
        let mobileVersion = try #require(before.noteCards[card.cardId]).questionVersion(in: scope)
        var next = type; next.revision += 1; next.css += "\n.meaning{font-size:28px}"
        try fixture.db.saveReviewNoteType(next, expected: type, scope: scope)
        #expect(throws: (any Error).self) {
            try fixture.db.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
                reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), card: card,
                action: .init(content: before, selection: selection))
        }
        #expect(throws: (any Error).self) {
            try fixture.db.submitReview(workspaceId: scope.workspaceId, reviewSubmission: .init(cardId: card.cardId,
                rating: .good, reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC", noteVersion: mobileVersion))
        }
        let after = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        #expect(throws: (any Error).self) {
            try fixture.db.saveCard(workspaceId: scope.workspaceId, input: .init(frontText: "override", backText: "answer", tags: []),
                cardId: card.cardId, mediaAssetIdsReadyForUpload: [])
        }
        #expect(after.queue.first == card)
        #expect(after.noteCards[card.cardId]?.noteType.css == next.css)
        #expect(throws: (any Error).self) { try fixture.db.saveReviewNoteType(next, expected: type, scope: scope) }
    }
    @Test func sourceAndCustomFieldsStayIndependentAndFailedBatchRollsBack() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selection) = try source(fixture)
        var type = ReviewNoteDefaults.type; type.id = UUID()
        let field = ReviewNoteField(name: "Hint", source: .custom)
        type.fields.append(field); type.templates[0].back += "<p>{{Hint}}</p>"
        try fixture.db.saveReviewNoteType(type, expected: nil, scope: scope)
        #expect(throws: (any Error).self) {
            try fixture.db.enrollReviewNotes(selections: [selection, .init(entryID: UUID(), senseID: UUID())], type: type, scope: scope)
        }
        #expect(try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date()).noteCards.isEmpty)
        let note = try #require(fixture.db.enrollReviewNotes(selections: [selection], type: type, scope: scope).first)
        var edited = note; edited.revision += 1; edited.customFields[field.id.uuidString.lowercased()] = "<b>My hint</b>"
        try fixture.db.saveReviewNote(edited, expected: note, scope: scope)
        var document = scope.document
        let index = try #require(document.entries.firstIndex { $0.id == selection.entryID })
        let sense = try #require(document.entries[index].senses.firstIndex { $0.id == selection.senseID })
        document.entries[index].senses[sense].meaning = "Updated meaning"
        let updated = try fixture.db.saveLingroveNotebook(document, basedOn: scope)
        let after = try fixture.db.loadBuiltInNotebookReview(scope: updated, now: Date())
        let model = try #require(after.noteCards.values.first)
        let rendered = try model.render(in: updated)
        #expect(rendered.backHTML.contains("Updated meaning") && rendered.backHTML.contains("<b>My hint</b>"))
        #expect(model.note.customFields == edited.customFields)
    }
    @Test func savingPresetAsDefaultPreservesExistingCardAndHistory() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selection) = try source(fixture)
        let original = ReviewNoteDefaults.type
        _ = try fixture.db.enrollReviewNotes(selections: [selection], type: original, scope: scope)
        let review = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let card = try #require(review.queue.first)
        _ = try fixture.db.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), card: card,
            action: .init(content: review, selection: selection))
        let before = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let preset = try #require(ReviewNoteDefaults.presets.first { $0.id == "bilateral-recall" })
        let newType = ReviewNoteDefaults.makeType(preset, basedOn: original)
        try fixture.db.saveReviewNoteType(newType, expected: nil, scope: scope, makeDefault: true)
        try fixture.reopen()
        let after = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        #expect(after.defaultNoteType == newType)
        #expect(after.noteCards == before.noteCards)
        #expect(after.review.groups[selection.senseID]?.cards == before.review.groups[selection.senseID]?.cards)
        #expect(after.statistics.ratingRecords == 1)
    }

    private func source(_ fixture: NotebookMediaDatabaseFixture) throws -> (LingroveNotebookSnapshot, VocabularySelection) {
        let scope = try fixture.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        let entry = try #require(scope.document.collectedEntries.first), sense = try #require(entry.senses.first)
        return (scope, .init(entryID: entry.id, senseID: sense.id))
    }
}
