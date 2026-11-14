import Foundation
import LingroveNotebook
import Testing
@testable import LingroveNotebookEngine

/// Storage integration exercises the actual source projection, native Card writer, queue
/// admission and scheduler/event persistence in one database, including restart boundaries.
@MainActor
struct LingroveNotebookReviewCompletionTests {



    @Test("A bounded offline batch retains an undo whose event and schedule are beyond the sent prefix")
    func offlineBatchUndoDependency() throws {
        let f = try NotebookMediaDatabaseFixture(); defer { f.cleanUp() }
        let saved = try f.db.saveLingroveNotebook(Self.document(), basedOn: f.db.loadLingroveNotebook(workspaceId: f.workspace))
        let selection = VocabularySelection(entryID: saved.document.entries[0].id, senseID: saved.document.entries[0].senses[0].id)
        let owner = try #require(try f.db.enrollNoteSources([selection], scope: saved).first)
        let card = try #require(try f.db.lingroveNotebookReviewStore.exercises(owner).first).cardId
        let start = Date()
        for index in 0..<201 {
            _ = try f.db.submitTestNoteRating(.init(cardId: card, rating: .again,
                reviewedAtClient: formatIsoTimestamp(date: start.addingTimeInterval(Double(index))),
                reviewedTimeZone: "UTC"), basedOn: saved)
        }
        try f.db.undoLastNotebookRating(workspaceId: f.workspace, cardId: card,
            generation: f.db.loadLingroveNotebook(workspaceId: f.workspace).generation)
        let request = try LingroveNotebookReviewSyncStore(core: f.db.core).request(f.binding())
        // One initial Card plus 199 complete rating/event pairs. The last
        // unpaired event waits with its schedule instead of filling slot 400.
        #expect(request.operations.count == 399)
        #expect(request.undos.isEmpty)
        #expect(try f.db.loadReviewEventCount() == 201)
        #expect(try f.db.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_review_undo WHERE pending=1", values: []) == 1)
        #expect(try f.db.loadActiveCard(workspaceId: f.workspace, cardId: card).reps == 200)
    }

    static func document() -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 1793580000)
        let example = VocabularyExample(id: UUID(), text: "We found a quiet harbor.", translation: "a translated example", ranges: [],
            completeness: .sentence, meaning: "a sheltered place", meaningLanguage: .english, meaningOrigin: .user, createdAt: now)
        let sense = VocabularySense(id: UUID(), meaning: "a sheltered place", meaningLanguage: .english, meaningOrigin: .user,
            examples: [example], isSavedWithoutContext: false, createdAt: now, updatedAt: now)
        let other = VocabularySense(id: UUID(), meaning: "to retain a thought", meaningLanguage: .english, meaningOrigin: .user,
            isSavedWithoutContext: true, createdAt: now, updatedAt: now)
        return .init(entries: [.init(id: UUID(), expression: "harbor", dictionaryForm: "harbor", language: .english,
            kind: .word, senses: [sense, other], createdAt: now, updatedAt: now)])
    }
}
