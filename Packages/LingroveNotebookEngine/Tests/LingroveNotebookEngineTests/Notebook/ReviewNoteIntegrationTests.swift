import Foundation
import Testing
import LingroveNotebook
@testable import LingroveNotebookEngine

@MainActor
struct ReviewNoteIntegrationTests {
    @Test func onlyNoteMembershipOwnsNativeQueueParticipationAndProgress() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selection) = try source(fixture)
        _ = try fixture.db.enrollReviewNotes(selections: [selection], version: .init(scope))
        let content = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let card = try #require(content.queue.first)
        _ = try fixture.db.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), card: card,
            action: .init(content: content, selection: selection))
        try fixture.db.core.execute(sql: "DELETE FROM notebook_note_cards WHERE workspace_id=? AND card_id=?",
            values: [.text(scope.workspaceId), .text(card.cardId)])
        let review = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        #expect(review.queue.isEmpty && review.review.groups.isEmpty && review.recentHistory.isEmpty)
        #expect(review.statistics.exercises == 0 && review.statistics.ratingRecords == 0)
        let participation = try fixture.db.loadNotebookParticipation(selection: selection, version: .init(scope))
        #expect(participation.status == nil && participation.exerciseCount == 0)
        let progress = try fixture.db.loadNotebookProgress(scope: fixture.db.notebookProgressReadFence().scope,
            now: Date(), calendar: .current)
        #expect(progress.totalReviews == 0 && progress.enrolledSenses == 0 && progress.schedule.totalCards == 0)
    }

    @Test func coldRatingUndoAndCardReadsKeepTheCorpusUnloaded() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selection) = try source(fixture)
        _ = try fixture.db.enrollReviewNotes(selections: [selection], version: .init(scope))
        try fixture.reopen()
        let version = LingroveNotebookVersion(scope), now = Date()
        let review = try fixture.db.loadBuiltInNotebookReview(version: version, now: now, savedScope: scope)
        let card = try #require(review.queue.first)
        let link = try #require(review.review.links.first { $0.cardId == card.cardId })
        let marker = try fixture.db.withBuiltInReviewCardRead(version: version, card: card, link: link) { "read" }
        #expect(marker == "read" && fixture.db.core.notebookSaveCache == nil)
        _ = try fixture.db.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: formatIsoTimestamp(date: now), reviewedTimeZone: "UTC"),
            card: card, action: .init(content: review, selection: selection))
        #expect(fixture.db.core.notebookSaveCache == nil)
        #expect(throws: (any Error).self) {
            try fixture.db.withBuiltInReviewCardRead(version: version, card: card, link: link) { "stale" }
        }
        let rated = try fixture.db.loadBuiltInNotebookReview(version: version, now: now, savedScope: scope)
        let undo = try #require(rated.undoByCardID[card.cardId])
        try fixture.db.undoBuiltInNotebookRating(undo, action: .init(content: rated, selection: selection))
        #expect(fixture.db.core.notebookSaveCache == nil)
        let restored = try #require(fixture.db.loadBuiltInNotebookReview(version: version, now: now, savedScope: scope).queue.first)
        #expect(restored.reps == card.reps && restored.frontText == card.frontText && restored.backText == card.backText)
    }

    @Test func enrollmentAndDestinationReadsAvoidReloadingTheCorpus() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        var document = LingroveNotebookReviewCompletionTests.document()
        document.catalog[0].senses[0].note = "Remember the harbor"
        document.catalog[0].senses[0].tags = ["nautical"]
        document.catalog[0].senses[0].content = [.init(content: .text(.init(text: "A safe place for ships")))]
        let scope = try fixture.db.saveLingroveNotebook(document,
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        let entry = try #require(scope.document.entries.first)
        let firstSense = try #require(entry.senses.first)
        let secondSense = try #require(entry.senses.last)
        let selection = VocabularySelection(entryID: entry.id, senseID: firstSense.id)
        let second = VocabularySelection(entryID: entry.id, senseID: secondSense.id)
        let version = LingroveNotebookVersion(scope)
        let now = Date()
        try fixture.reopen()
        let first = try #require(fixture.db.enrollReviewNotes(selections: [selection], version: version).first)
        #expect(first.exampleID == firstSense.examples.first?.id)
        #expect(fixture.db.core.notebookSaveCache == nil)

        let review = try fixture.db.loadBuiltInNotebookReview(version: version, now: now, savedScope: scope)
        let card = try #require(review.queue.first)
        #expect(card.backText.contains("We found a quiet harbor."))
        #expect(card.backText.contains("Remember the harbor"))
        #expect(card.backText.contains("A safe place for ships"))
        #expect(card.tags == ["nautical"])
        #expect(fixture.db.core.notebookSaveCache == nil)
        // Even a no-op write to the first card would fail, proving the next admission
        // never refreshes unrelated cards as part of its transaction.
        try fixture.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER protect_first_review_material BEFORE UPDATE ON notebook_review_material_state
            WHEN OLD.card_id = '\(card.cardId)'
            BEGIN SELECT RAISE(ABORT, 'Unrelated review material was refreshed'); END;
            """, errorContext: "Protect the first card's material in this fixture")
        _ = try fixture.db.enrollReviewNotes(selections: [second], version: version)
        let fence = try fixture.db.notebookProgressReadFence()
        let progress = try fixture.db.loadNotebookProgress(scope: fence.scope, now: now, calendar: .current)
        #expect(progress.enrolledSenses == 2 && progress.activeSenses == 2 && progress.exercises == 2)
        #expect(fixture.db.core.notebookSaveCache == nil)
    }

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
        let entry = try #require(scope.document.entries.first), sense = try #require(entry.senses.first)
        return (scope, .init(entryID: entry.id, senseID: sense.id))
    }
}
