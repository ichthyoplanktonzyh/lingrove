import Foundation
import Testing
import LingroveNotebook
@testable import LingroveNotebookEngine

/// These private SQLite fixtures enforce the writer boundary with poisoned unrelated payloads
/// and update triggers. A fast writer must still preserve memory and roll back late failures.
@MainActor
struct ReviewNoteScopedWriteTests {
    @Test(arguments: [false, true])
    func editingIgnoresUnrelatedNotesTypesAndMaterial(editType: Bool) throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selections, type) = try seed(fixture)
        let before = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let target = try #require(before.noteCards.values.first { $0.note.senseID == selections[0].senseID })
        let unrelated = try #require(before.noteCards.values.first { $0.note.senseID == selections[1].senseID })
        let unrelatedCard = try #require(before.review.groups[selections[1].senseID]?.cards.first)
        let store = ReviewNoteStore(core: fixture.db.core)
        let unrelatedType = try #require(try store.type(id: unrelated.note.noteTypeID, workspace: scope.workspaceId))
        // Valid JSON keeps the expression indexes usable while typed decoding would fail.
        try fixture.db.core.execute(sql: "UPDATE notebook_notes SET payload_json=? WHERE workspace_id=? AND note_id=?",
            values: [.text("{\"noteTypeID\":\"\(unrelatedType.id.uuidString)\"}"),
                .text(scope.workspaceId), .text(unrelated.note.id.uuidString)])
        try fixture.db.core.execute(sql: "UPDATE notebook_note_types SET payload_json='{}' WHERE workspace_id=? AND type_id=?",
            values: [.text(scope.workspaceId), .text(unrelatedType.id.uuidString)])
        try fixture.reopen()
        try fixture.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER protect_unrelated_note_material BEFORE UPDATE ON notebook_review_material_state
            WHEN OLD.card_id='\(unrelatedCard.cardId)'
            BEGIN SELECT RAISE(ABORT,'Unrelated material was refreshed'); END;
            """, errorContext: "Protect unrelated material")
        // Reopening proves the command does not borrow a warmed whole-corpus snapshot.
        if editType {
            var edited = type; edited.revision += 1; edited.templates[0].back += "<p>New template</p>"
            try fixture.db.saveReviewNoteType(edited, expected: type, scope: scope)
        } else {
            var edited = target.note; edited.revision += 1
            edited.customFields[type.fields.last!.id.uuidString.lowercased()] = "My hint"
            try fixture.db.saveReviewNote(edited, expected: target.note, scope: scope)
        }
        #expect(fixture.db.core.notebookSaveCache == nil)
        // Repair only the injected poison so the ordinary full reader can verify both cards.
        try ReviewNoteStore(core: fixture.db.core).put(unrelated.note, scope: scope)
        try ReviewNoteStore(core: fixture.db.core).put(unrelatedType, workspace: scope.workspaceId)
        let after = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        #expect(after.review.groups[selections[1].senseID]?.cards.first == unrelatedCard)
        #expect(after.noteCards.values.first { $0.note.id == target.note.id } != target)
        #expect(after.statistics.ratingRecords == before.statistics.ratingRecords)
    }

    @Test(arguments: [false, true])
    func lateMaterialFailureRollsBackDefinitionAndMemory(editType: Bool) throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selections, type) = try seed(fixture)
        let before = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let target = try #require(before.noteCards.values.first { $0.note.senseID == selections[0].senseID })
        try fixture.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER reject_note_refresh BEFORE UPDATE ON notebook_review_material_state
            BEGIN SELECT RAISE(ABORT,'Synthetic late material failure'); END;
            """, errorContext: "Fail after the definition has been written")
        #expect(throws: (any Error).self) {
            if editType {
                var edited = type; edited.revision += 1; edited.templates[0].back += "<p>Must roll back</p>"
                try fixture.db.saveReviewNoteType(edited, expected: type, scope: scope)
            } else {
                var edited = target.note; edited.revision += 1
                edited.customFields[type.fields.last!.id.uuidString.lowercased()] = "Must roll back"
                try fixture.db.saveReviewNote(edited, expected: target.note, scope: scope)
            }
        }
        let store = ReviewNoteStore(core: fixture.db.core)
        #expect(try store.note(id: target.note.id, version: .init(scope)) == target.note)
        #expect(try store.type(id: type.id, workspace: scope.workspaceId) == type)
        let after = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        #expect(after.noteCards == before.noteCards)
        #expect(after.review.links == before.review.links)
        #expect(after.review.groups.mapValues(\.cards) == before.review.groups.mapValues(\.cards))
        #expect(after.statistics.ratingRecords == 1)
    }

    @Test func styleEditDoesNotRefreshAnyCardButFencesTheOldQuestion() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selections, type) = try seed(fixture)
        let before = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let card = try #require(before.review.groups[selections[0].senseID]?.cards.first)
        try fixture.db.core.executeScript(sql: """
            CREATE TEMP TRIGGER protect_style_material BEFORE UPDATE ON notebook_review_material_state
            BEGIN SELECT RAISE(ABORT,'Style edit attempted a material refresh'); END;
            """, errorContext: "Protect all material from a style-only update")
        var next = type; next.revision += 1; next.css += "\np{font-size:22px}"
        try fixture.db.saveReviewNoteType(next, expected: type, scope: scope)
        let after = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        #expect(after.review.groups.mapValues(\.cards) == before.review.groups.mapValues(\.cards))
        #expect(after.noteCards[card.cardId]?.noteType == next && after.statistics.ratingRecords == 1)
        #expect(throws: (any Error).self) {
            try fixture.db.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
                reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), card: card,
                action: .init(content: before, selection: selections[0]))
        }
    }

    @Test func conditionalTemplateAppearsWithoutReplacingRatedCard() throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selections, original) = try seed(fixture)
        var type = original; type.revision += 1
        type.templates.append(.init(name: "Hint recall", front: "{{#Hint}}{{Hint}}{{/Hint}}", back: "{{Expression}}"))
        try fixture.db.saveReviewNoteType(type, expected: original, scope: scope)
        let before = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let rated = try #require(before.review.groups[selections[0].senseID]?.cards.first)
        let note = try #require(before.noteCards[rated.cardId]).note
        var edited = note; edited.revision += 1
        edited.customFields[type.fields.last!.id.uuidString.lowercased()] = "A new question"
        try fixture.db.saveReviewNote(edited, expected: note, scope: scope)
        let after = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let cards = try #require(after.review.groups[selections[0].senseID]?.cards)
        #expect(cards.count == 2)
        let kept = try #require(cards.first { $0.cardId == rated.cardId })
        #expect(kept.reps == rated.reps && kept.dueAt == rated.dueAt && kept.fsrsStability == rated.fsrsStability)
        #expect(after.statistics.ratingRecords == 1)
    }

    @Test(arguments: [false, true])
    func editsAfterSourceRetirementOrMergePreserveMemory(merge: Bool) throws {
        let fixture = try NotebookMediaDatabaseFixture(); defer { fixture.cleanUp() }
        let (scope, selections, type) = try seed(fixture)
        let before = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let card = try #require(before.review.groups[selections[0].senseID]?.cards.first)
        let note = try #require(before.noteCards[card.cardId]).note
        var document = scope.document
        if merge {
            try VocabularySenseEditingPolicy.merge(entryID: selections[0].entryID,
                source: selections[0].senseID, into: selections[1].senseID, in: &document, now: Date())
        } else {
            try VocabularySenseEditingPolicy.remove(entryID: selections[0].entryID,
                senseID: selections[0].senseID, from: &document)
        }
        let updated = try fixture.db.saveLingroveNotebook(document, basedOn: scope)
        try fixture.reopen()
        var edited = note; edited.revision += 1
        edited.customFields[type.fields.last!.id.uuidString.lowercased()] = "Retained authored hint"
        try fixture.db.saveReviewNote(edited, expected: note, scope: updated)
        var nextType = type; nextType.revision += 1; nextType.templates[0].back += "<p>Updated question</p>"
        try fixture.db.saveReviewNoteType(nextType, expected: type, scope: updated)
        #expect(fixture.db.core.notebookSaveCache == nil)
        let after = try fixture.db.loadBuiltInNotebookReview(scope: updated, now: Date())
        let kept = try fixture.db.cardStore.loadCard(workspaceId: scope.workspaceId, cardId: card.cardId)
        #expect(kept.reps == card.reps && kept.dueAt == card.dueAt && kept.fsrsStability == card.fsrsStability)
        #expect(after.noteCards[card.cardId]?.note == edited && after.statistics.ratingRecords == 1)
        if merge {
            #expect(after.eligibleCardIDs.contains(card.cardId))
            #expect(kept.backText.contains("Retained authored hint") && kept.backText.contains("Updated question"))
        } else {
            #expect(!after.eligibleCardIDs.contains(card.cardId))
            #expect(after.review.groups[selections[0].senseID]?.hasUnavailableMaterial == true)
            #expect(kept == card)
        }
    }

    private func seed(_ fixture: NotebookMediaDatabaseFixture) throws
        -> (LingroveNotebookSnapshot, [VocabularySelection], ReviewNoteType) {
        let scope = try fixture.db.saveLingroveNotebook(LingroveNotebookReviewCompletionTests.document(),
            basedOn: fixture.db.loadLingroveNotebook(workspaceId: fixture.workspace))
        let entry = try #require(scope.document.entries.first)
        let selections = entry.senses.map { VocabularySelection(entryID: entry.id, senseID: $0.id) }
        var type = ReviewNoteDefaults.type; type.id = UUID(); type.name = "Scoped custom type"
        type.fields.append(.init(name: "Hint", source: .custom))
        type.templates[0].back += "<p>{{Hint}}</p>"
        try fixture.db.saveReviewNoteType(type, expected: nil, scope: scope)
        _ = try fixture.db.enrollReviewNotes(selections: [selections[0]], type: type, scope: scope)
        _ = try fixture.db.enrollReviewNotes(selections: [selections[1]], type: ReviewNoteDefaults.type, scope: scope)
        let content = try fixture.db.loadBuiltInNotebookReview(scope: scope, now: Date())
        let card = try #require(content.review.groups[selections[0].senseID]?.cards.first)
        _ = try fixture.db.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
            reviewedAtClient: nowIsoTimestamp(), reviewedTimeZone: "UTC"), card: card,
            action: .init(content: content, selection: selections[0]))
        return (scope, selections, type)
    }
}
